#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"

echo "============================================"
echo "  K8ssandra Workshop - Full Deployment"
echo "============================================"
echo ""

# Check prerequisites
for cmd in kubectl helm; do
  if ! command -v $cmd &> /dev/null; then
    echo "ERROR: $cmd is required but not installed."
    exit 1
  fi
done

echo "Current kubectl context:"
kubectl config current-context
echo ""
read -p "Continue with this context? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

# Step 1: StorageClass
echo ""
echo ">>> Step 1/6: Creating EBS gp3 StorageClass..."
kubectl apply -f "$MANIFESTS_DIR/infra/storageclass.yaml"

# Step 2: cert-manager
echo ""
echo ">>> Step 2/6: Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack
if helm status cert-manager -n cert-manager &>/dev/null; then
  echo "    cert-manager already installed, skipping."
else
  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --set crds.enabled=true \
    --wait --timeout 5m
fi

# Step 3: k8ssandra-operator
echo ""
echo ">>> Step 3/6: Installing k8ssandra-operator..."
helm repo add k8ssandra https://helm.k8ssandra.io/stable 2>/dev/null || true
helm repo update k8ssandra
if helm status k8ssandra-operator -n default &>/dev/null; then
  echo "    k8ssandra-operator already installed, skipping."
else
  helm install k8ssandra-operator k8ssandra/k8ssandra-operator \
    --namespace default \
    --wait --timeout 5m
fi

# Step 4: K8ssandraCluster
echo ""
echo ">>> Step 4/6: Deploying Cassandra cluster..."
kubectl apply -f "$MANIFESTS_DIR/cassandra/k8ssandra-cluster.yaml"
echo "    Waiting for Cassandra pods to be ready (this may take 3-5 minutes)..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=cassandra \
  -n default \
  --timeout=600s 2>/dev/null || echo "    (Pods still starting — check with: kubectl get pods -l app.kubernetes.io/name=cassandra)"

# Step 5: easy-cass-mcp
echo ""
echo ">>> Step 5/6: Deploying easy-cass-mcp..."
kubectl apply -f "$MANIFESTS_DIR/apps/easy-cass-mcp-deployment.yaml"
kubectl apply -f "$MANIFESTS_DIR/apps/easy-cass-mcp-service.yaml"
echo "    Waiting for easy-cass-mcp to be ready..."
kubectl wait --for=condition=available deployment/easy-cass-mcp \
  -n default --timeout=120s 2>/dev/null || echo "    (Deployment still progressing)"

# Step 6: NoSQLBench workload config
echo ""
echo ">>> Step 6/6: Deploying NoSQLBench workload ConfigMap..."
kubectl apply -f "$MANIFESTS_DIR/loadtest/nosqlbench-configmap.yaml"
echo "    ConfigMap ready. To run the load test:"
echo "    kubectl apply -f $MANIFESTS_DIR/loadtest/nosqlbench-job.yaml"

# Print summary
echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "Cassandra superuser credentials:"
echo "  Username: $(kubectl get secret demo-superuser -o jsonpath='{.data.username}' | base64 -d)"
echo "  Password: $(kubectl get secret demo-superuser -o jsonpath='{.data.password}' | base64 -d)"
echo ""

NLB_HOST=$(kubectl get svc easy-cass-mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$NLB_HOST" ]; then
  echo "easy-cass-mcp endpoint:"
  echo "  http://$NLB_HOST:8000/mcp/"
  echo ""
  echo "Claude Desktop config (add to claude_desktop_config.json):"
  echo '  "cassandra": {'
  echo '    "command": "npx",'
  echo "    \"args\": [\"mcp-remote\", \"http://$NLB_HOST:8000/mcp/\", \"--allow-http\"]"
  echo '  }'
else
  echo "NLB not ready yet. Check with:"
  echo "  kubectl get svc easy-cass-mcp"
fi
echo ""

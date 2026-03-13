#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"

# Configurable parameters
CLUSTER_NAME="${CLUSTER_NAME:-k8ssandra-cluster}"
REGION="${REGION:-us-east-1}"

echo "============================================"
echo "  K8ssandra Workshop - Full Deployment"
echo "============================================"
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "Region:  $REGION"
echo ""

# Check prerequisites
for cmd in kubectl helm aws; do
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
echo ">>> Step 1/5: Creating EBS gp3 StorageClass..."
kubectl apply -f "$MANIFESTS_DIR/infra/storageclass.yaml"

# Step 2: cert-manager
echo ""
echo ">>> Step 2/5: Installing cert-manager..."
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
echo ">>> Step 3/5: Installing k8ssandra-operator..."
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
echo ">>> Step 4/5: Deploying Cassandra cluster..."
kubectl apply -f "$MANIFESTS_DIR/cassandra/k8ssandra-cluster.yaml"
echo "    Waiting for Cassandra pods to be ready (this may take 3-5 minutes)..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=cassandra \
  -n default \
  --timeout=600s 2>/dev/null || echo "    (Pods still starting — check with: kubectl get pods -l app.kubernetes.io/name=cassandra)"

# Step 5: easy-cass-mcp + NoSQLBench
echo ""
echo ">>> Step 5/5: Deploying easy-cass-mcp and NoSQLBench..."
kubectl apply -f "$MANIFESTS_DIR/apps/easy-cass-mcp-deployment.yaml"
kubectl apply -f "$MANIFESTS_DIR/apps/easy-cass-mcp-service.yaml"
kubectl apply -f "$MANIFESTS_DIR/loadtest/nosqlbench-configmap.yaml"
echo "    Waiting for easy-cass-mcp to be ready..."
kubectl wait --for=condition=available deployment/easy-cass-mcp \
  -n default --timeout=120s 2>/dev/null || echo "    (Deployment still progressing)"
echo ""
echo "    NoSQLBench ConfigMap ready. To run the load test:"
echo "    kubectl apply -f $MANIFESTS_DIR/loadtest/nosqlbench-job.yaml"

# Wait for NLB to provision
echo ""
echo ">>> Waiting for NLB to provision (this may take 1-3 minutes)..."
NLB_HOST=""
for i in $(seq 1 36); do
  NLB_HOST=$(kubectl get svc easy-cass-mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$NLB_HOST" ]; then
    break
  fi
  printf "    Waiting... (%ds)\r" $((i * 5))
  sleep 5
done
echo ""

# Print summary
echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "Cassandra superuser credentials:"
echo "  Username: $(kubectl get secret demo-superuser -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || echo '<not yet available>')"
echo "  Password: $(kubectl get secret demo-superuser -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo '<not yet available>')"
echo ""

if [ -n "$NLB_HOST" ]; then
  echo "easy-cass-mcp endpoint:"
  echo "  http://$NLB_HOST:8000/mcp/"
  echo ""
  echo "Claude Desktop config (add to claude_desktop_config.json):"
  echo '  "cassandra": {'
  echo '    "command": "npx",'
  echo "    \"args\": [\"mcp-remote\", \"http://$NLB_HOST:8000/mcp/\", \"--allow-http\"]"
  echo '  }'
  echo ""

  # Update .mcp.json with the new NLB hostname so Claude Code picks it up on next restart
  MCP_JSON="$SCRIPT_DIR/../.mcp.json"
  cat > "$MCP_JSON" <<EOF
{
  "mcpServers": {
    "easy-cass-mcp": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "http://$NLB_HOST:8000/mcp/",
        "--allow-http"
      ]
    }
  }
}
EOF
  echo ".mcp.json updated with new NLB hostname."
  echo "Restart Claude Code to reconnect easy-cass-mcp."
else
  echo "NLB not ready yet. Check with:"
  echo "  kubectl get svc easy-cass-mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
  echo ""
  echo "If the NLB never provisions, verify your cluster was created with the"
  echo "provided eksctl ClusterConfig (eksctl tags subnets automatically)."
fi
echo ""

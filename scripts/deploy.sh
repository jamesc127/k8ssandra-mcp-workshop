#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"

# Configurable parameters
CLUSTER_NAME="${CLUSTER_NAME:-k8ssandra-cluster}"
REGION="${REGION:-us-east-1}"

# Chart versions are PINNED deliberately. An unpinned chart that bumps between
# rehearsal and a live demo is the single easiest way to break a working setup.
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"
METRICS_SERVER_CHART_VERSION="${METRICS_SERVER_CHART_VERSION:-3.14.0}"
KPS_CHART_VERSION="${KPS_CHART_VERSION:-91.4.0}"
K8SSANDRA_OPERATOR_VERSION="${K8SSANDRA_OPERATOR_VERSION:-1.33.0}"

# Which CR profile to deploy: the 5-node trial (default) or the 9-node full one.
CASSANDRA_CR="${CASSANDRA_CR:-$MANIFESTS_DIR/cassandra/k8ssandra-cluster.yaml}"

# Grafana admin password for the kube-prometheus-stack release.
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-workshop}"

echo "============================================"
echo "  K8ssandra Workshop - Full Deployment"
echo "============================================"
echo ""
echo "Cluster:  $CLUSTER_NAME"
echo "Region:   $REGION"
echo "CR:       $(basename "$CASSANDRA_CR")"
echo "Operator: $K8SSANDRA_OPERATOR_VERSION"
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

# ---------------------------------------------------------------------------
# Step 1: Preflight
#
# These checks are cheap and they all guard against failures that otherwise
# surface 20 minutes later, or silently never surface at all.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 1/9: Preflight checks..."

echo "    Node topology:"
kubectl get nodes \
  -L topology.kubernetes.io/zone,workload \
  --no-headers -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,WORKLOAD:.metadata.labels.workload' \
  | sed 's/^/      /'

CASS_AZS=$(kubectl get nodes -l workload=cassandra \
  -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' \
  | sort -u | grep -c . || true)
if [ "$CASS_AZS" -lt 3 ]; then
  echo ""
  echo "ERROR: Cassandra nodes span $CASS_AZS availability zone(s); 3 are required."
  echo "       The rack-per-AZ layout needs 3 racks, because Cassandra's default"
  echo "       allocate_tokens_for_local_replication_factor=3 stalls bootstrap"
  echo "       otherwise. Fix the node group's availabilityZones before continuing."
  exit 1
fi
echo "    Cassandra nodes span $CASS_AZS AZs. OK."

if ! kubectl get nodes -l workload=loadgen --no-headers 2>/dev/null | grep -q .; then
  echo "    WARNING: no node labelled workload=loadgen."
  echo "             NoSQLBench jobs will stay Pending until one exists."
fi

if grep -q 'REPLACE_WITH_MEDUSA_BUCKET' "$CASSANDRA_CR"; then
  echo ""
  echo "ERROR: $CASSANDRA_CR still has the Medusa bucket placeholder."
  echo "       Follow manifests/infra/medusa-irsa.md, then replace it."
  exit 1
fi

MEDUSA_ROLE_ARN=$(kubectl get sa medusa-backup -n default \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
if [ -z "$MEDUSA_ROLE_ARN" ]; then
  echo ""
  echo "ERROR: ServiceAccount 'medusa-backup' is missing or has no IRSA annotation."
  echo "       Medusa cannot reach S3 without it. This script does not create IAM"
  echo "       resources — see manifests/infra/medusa-irsa.md."
  exit 1
fi
echo "    Medusa IRSA role: $MEDUSA_ROLE_ARN"

# ---------------------------------------------------------------------------
# Step 2: StorageClass
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 2/9: Creating EBS gp3 StorageClass..."
kubectl apply -f "$MANIFESTS_DIR/infra/storageclass.yaml"

# ---------------------------------------------------------------------------
# Step 3: cert-manager
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 3/9: Installing cert-manager ($CERT_MANAGER_VERSION)..."
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack
if helm status cert-manager -n cert-manager &>/dev/null; then
  echo "    cert-manager already installed, skipping."
else
  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --wait --timeout 5m
fi

# ---------------------------------------------------------------------------
# Step 4: metrics-server
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 4/9: Installing metrics-server ($METRICS_SERVER_CHART_VERSION)..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update metrics-server
if helm status metrics-server -n kube-system &>/dev/null; then
  echo "    metrics-server already installed, skipping."
else
  helm install metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    --version "$METRICS_SERVER_CHART_VERSION" \
    --wait --timeout 2m
fi

# ---------------------------------------------------------------------------
# Step 5: kube-prometheus-stack
#
# MUST come before k8ssandra-operator. The operator decides whether to emit
# ServiceMonitors by checking whether the ServiceMonitor CRD is registered, via
# a cached RESTMapper. A CRD that appears after the operator pod has started is
# not seen, and telemetry is skipped silently with no error on the CR.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 5/9: Installing kube-prometheus-stack ($KPS_CHART_VERSION)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community
KPS_INSTALLED_NOW=false
if helm status kps -n monitoring &>/dev/null; then
  echo "    kube-prometheus-stack already installed, skipping."
else
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  helm install kps prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --version "$KPS_CHART_VERSION" \
    -f "$MANIFESTS_DIR/monitoring/values-kube-prometheus-stack.yaml" \
    --set grafana.adminPassword="$GRAFANA_PASSWORD" \
    --wait --timeout 10m
  KPS_INSTALLED_NOW=true
fi

# Cassandra dashboards, if present. Build these against the live metric names —
# published k8ssandra dashboards target the deprecated MCAC endpoint
# (collectd_mcac_*) and render empty against Cassandra 5's mgmt-api metrics.
if compgen -G "$MANIFESTS_DIR/monitoring/grafana-dashboard-*.yaml" > /dev/null; then
  kubectl apply -f "$MANIFESTS_DIR"/monitoring/grafana-dashboard-*.yaml
else
  echo "    (No Grafana dashboard ConfigMaps yet — see docs/TROUBLESHOOTING.md)"
fi

# ---------------------------------------------------------------------------
# Step 6: k8ssandra-operator
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 6/9: Installing k8ssandra-operator ($K8SSANDRA_OPERATOR_VERSION)..."
helm repo add k8ssandra https://helm.k8ssandra.io/stable 2>/dev/null || true
helm repo update k8ssandra
if helm status k8ssandra-operator -n default &>/dev/null; then
  echo "    k8ssandra-operator already installed, skipping."
  if [ "$KPS_INSTALLED_NOW" = true ]; then
    echo "    Prometheus CRDs were installed in this run — restarting operator so"
    echo "    it picks up the ServiceMonitor CRD."
    kubectl rollout restart deployment/k8ssandra-operator -n default
    kubectl rollout status deployment/k8ssandra-operator -n default --timeout=3m
  fi
else
  helm install k8ssandra-operator k8ssandra/k8ssandra-operator \
    --namespace default \
    --version "$K8SSANDRA_OPERATOR_VERSION" \
    --wait --timeout 5m
fi

# ---------------------------------------------------------------------------
# Step 7: K8ssandraCluster
#
# The old `kubectl wait --for=condition=ready pod` was the wrong signal: it
# returns as soon as the pods that currently EXIST are ready, so it can succeed
# after pod 0 while the rest have not been created. CassandraDatacenter's Ready
# condition is the operator-owned signal that every rack is fully bootstrapped.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 7/9: Deploying Cassandra cluster..."
kubectl apply -f "$CASSANDRA_CR"

echo "    Waiting for CassandraDatacenter/dc1 to be Ready."
echo "    Bootstraps are serial — budget ~2-2.5 min per node."

# Progress ticker, so a long wait doesn't look like a hang.
(
  while true; do
    sleep 30
    kubectl get pods -l app.kubernetes.io/name=cassandra -n default \
      -o custom-columns='POD:.metadata.name,RACK:.metadata.labels.cassandra\.datastax\.com/rack,READY:.status.containerStatuses[*].ready' \
      --no-headers 2>/dev/null | sed 's/^/      /' || true
    echo "      ---"
  done
) &
TICKER=$!
trap 'kill $TICKER 2>/dev/null || true' EXIT

kubectl wait --for=condition=Ready cassandradatacenter/dc1 -n default --timeout=2400s \
  || echo "    WARNING: datacenter not Ready within timeout — check 'kubectl describe cassandradatacenter dc1'"

kill $TICKER 2>/dev/null || true
trap - EXIT

echo ""
echo "    Rack balance:"
kubectl get pods -l app.kubernetes.io/name=cassandra -n default \
  -o jsonpath='{range .items[*]}{.metadata.labels.cassandra\.datastax\.com/rack}{"\n"}{end}' \
  | sort | uniq -c | sed 's/^/      /'
echo "    (counts should be equal across rack1/rack2/rack3)"

# ---------------------------------------------------------------------------
# Step 8: easy-cass-mcp + NoSQLBench
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 8/9: Deploying easy-cass-mcp and NoSQLBench..."
kubectl apply -f "$MANIFESTS_DIR/apps/easy-cass-mcp-deployment.yaml"
kubectl apply -f "$MANIFESTS_DIR/apps/easy-cass-mcp-service.yaml"
kubectl apply -f "$MANIFESTS_DIR/loadtest/nosqlbench-payments-configmap.yaml"
echo "    Waiting for easy-cass-mcp to be ready..."
kubectl wait --for=condition=available deployment/easy-cass-mcp \
  -n default --timeout=120s 2>/dev/null || echo "    (Deployment still progressing)"

# easy-cass-mcp commonly comes up before the superuser secret is usable and
# then sits there with "Bad credentials". Restarting once after Cassandra is
# Ready is cheaper than debugging it later.
echo "    Restarting easy-cass-mcp to pick up superuser credentials..."
kubectl rollout restart deployment/easy-cass-mcp -n default
kubectl rollout status deployment/easy-cass-mcp -n default --timeout=3m || true

echo ""
echo "    NoSQLBench is a two-stage workload now:"
echo "      1. kubectl apply -f $MANIFESTS_DIR/loadtest/nosqlbench-payments-prepare-job.yaml   # schema + bulk load"
echo "      2. kubectl apply -f $MANIFESTS_DIR/loadtest/nosqlbench-payments-job.yaml           # sustained load"

# ---------------------------------------------------------------------------
# Step 9: NLB
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 9/9: Waiting for NLB to provision (this may take 1-3 minutes)..."
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
echo "Grafana:"
echo "  kubectl port-forward -n monitoring svc/kps-grafana 3000:80"
echo "  http://localhost:3000  (admin / $GRAFANA_PASSWORD)"
echo ""
echo "Reaper:"
echo "  kubectl port-forward -n default svc/demo-dc1-reaper-service 8080:8080"
echo "  http://localhost:8080/webui/index.html"
echo ""
echo "Medusa backups:"
echo "  kubectl apply -f $MANIFESTS_DIR/cassandra/medusa-backup-job.yaml"
echo "  kubectl get medusabackup -n default"
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
  echo ""
  echo "NOTE: claude_desktop_config.json is NOT updated automatically."
else
  echo "NLB not ready yet. Check with:"
  echo "  kubectl get svc easy-cass-mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
  echo ""
  echo "If the NLB never provisions, verify your cluster was created with the"
  echo "provided eksctl ClusterConfig (eksctl tags subnets automatically)."
fi
echo ""

#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"
OCP_DIR="$MANIFESTS_DIR/openshift"

# Chart versions pinned — an unpinned chart that bumps between rehearsal and a
# live demo is the easiest way to break a working setup.
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"
KPS_CHART_VERSION="${KPS_CHART_VERSION:-91.4.0}"
K8SSANDRA_OPERATOR_VERSION="${K8SSANDRA_OPERATOR_VERSION:-1.33.0}"

NAMESPACE="${NAMESPACE:-default}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-workshop}"
RENDERED_CR="${TMPDIR:-/tmp}/k8ssandra-cluster.openshift.rendered.yaml"

echo "============================================"
echo "  K8ssandra Workshop - OpenShift Deployment"
echo "============================================"
echo ""
echo "Namespace: $NAMESPACE"
echo "Operator:  $K8SSANDRA_OPERATOR_VERSION"
echo ""

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

# ---------------------------------------------------------------------------
# Step 1: Preflight
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 1/8: Preflight checks..."

# Route and SCC are served by the OpenShift API server as aggregated APIs, not
# as CRDs — `kubectl get crd routes.route.openshift.io` finds nothing even on a
# healthy OpenShift cluster. Probe the API groups instead.
for group in route.openshift.io security.openshift.io; do
  if ! kubectl get --raw "/apis/$group/v1" &>/dev/null; then
    echo "ERROR: API group $group/v1 not served — this does not look like OpenShift."
    echo "       For EKS, use scripts/deploy.sh instead."
    exit 1
  fi
done
# security.openshift.io/v1 being present is also what cass-operator keys off to
# enable its OpenShift mode and omit runAsUser/runAsGroup.
echo "    OpenShift API groups present (route, security). OK."

echo "    Node layout:"
kubectl get nodes -L workload,k8ssandra.io/rack --no-headers \
  -o custom-columns='NAME:.metadata.name,WORKLOAD:.metadata.labels.workload,RACK:.metadata.labels.k8ssandra\.io/rack' \
  | sed 's/^/      /'

RACKS=$(kubectl get nodes -l workload=cassandra \
  -o jsonpath='{range .items[*]}{.metadata.labels.k8ssandra\.io/rack}{"\n"}{end}' \
  | sort -u | grep -c . || true)
if [ "$RACKS" -lt 3 ]; then
  echo ""
  echo "ERROR: found $RACKS distinct rack label(s) on workload=cassandra nodes; 3 are required."
  echo "       Cassandra's default allocate_tokens_for_local_replication_factor=3"
  echo "       needs 3 racks — with fewer, bootstrap stalls rather than failing."
  echo "       Run: $OCP_DIR/node-labels.sh"
  exit 1
fi
echo "    Found $RACKS racks on Cassandra nodes. OK."

if ! kubectl get nodes -l workload=loadgen --no-headers 2>/dev/null | grep -q .; then
  echo "    WARNING: no node labelled workload=loadgen — NoSQLBench jobs will stay Pending."
fi

if ! kubectl get storageclass ocs-storagecluster-ceph-rbd &>/dev/null; then
  echo "ERROR: StorageClass 'ocs-storagecluster-ceph-rbd' not found."
  echo "       Available:"
  kubectl get storageclass --no-headers -o custom-columns='NAME:.metadata.name' | sed 's/^/         /'
  exit 1
fi
echo "    StorageClass ocs-storagecluster-ceph-rbd present. OK."

# ---------------------------------------------------------------------------
# Step 2: cert-manager
#
# OpenShift's service-ca does not satisfy the operator's webhook chart, which
# expects cert-manager. The metrics-server step from the EKS script is omitted:
# OpenShift already serves metrics.k8s.io.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 2/8: Installing cert-manager ($CERT_MANAGER_VERSION)..."
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack >/dev/null
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
# Step 3: kube-prometheus-stack
#
# --skip-crds is MANDATORY here. The monitoring.coreos.com CRDs are installed
# and owned by OpenShift's cluster-version-operator; letting Helm manage them
# would conflict with the platform.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 3/8: Installing kube-prometheus-stack ($KPS_CHART_VERSION)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community >/dev/null
if helm status kps -n monitoring &>/dev/null; then
  echo "    kube-prometheus-stack already installed, skipping."
else
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  helm install kps prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --version "$KPS_CHART_VERSION" \
    --skip-crds \
    -f "$OCP_DIR/values-kube-prometheus-stack.yaml" \
    --set grafana.adminPassword="$GRAFANA_PASSWORD" \
    --wait --timeout 10m
fi

# Second Grafana datasource: OpenShift's own Thanos Querier. Our Prometheus
# does not scrape the kubelet, so container_cpu_* — including
# container_cpu_cfs_throttled_seconds_total — lives only in the platform stack.
# The token is minted here rather than committed.
echo "    Wiring OpenShift Thanos as a Grafana datasource..."
kubectl apply -f "$OCP_DIR/thanos-datasource-rbac.yaml"
THANOS_TOKEN=$(kubectl create token grafana-thanos -n monitoring --duration=8760h 2>/dev/null || true)
if [ -n "$THANOS_TOKEN" ]; then
  kubectl create secret generic grafana-datasource-thanos \
    -n monitoring \
    --from-literal=thanos-datasource.yaml="apiVersion: 1
datasources:
  - name: OpenShift Thanos
    uid: openshift-thanos
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc:9091
    isDefault: false
    editable: false
    jsonData:
      timeInterval: 30s
      tlsSkipVerify: true
      httpHeaderName1: Authorization
    secureJsonData:
      httpHeaderValue1: Bearer $THANOS_TOKEN" \
    --dry-run=client -o yaml \
    | kubectl label -f - --local -o yaml --dry-run=client grafana_datasource=1 \
    | kubectl apply -f -
  # The datasource sidecar only reads on change, so nudge Grafana.
  kubectl rollout restart deployment/kps-grafana -n monitoring >/dev/null 2>&1 || true
else
  echo "    WARNING: could not mint a Thanos token; pod metrics will be missing from Grafana."
fi

if compgen -G "$MANIFESTS_DIR/monitoring/grafana-dashboard-*.yaml" > /dev/null; then
  kubectl apply -f "$MANIFESTS_DIR"/monitoring/grafana-dashboard-*.yaml
else
  echo "    (No Grafana dashboard ConfigMaps yet — see docs/TROUBLESHOOTING.md)"
fi

# OpenShift enables the OwnerReferencesPermissionEnforcement admission plugin,
# which vanilla Kubernetes does not. Both charts grant only `patch` on the
# `finalizers` subresources they need `update` on, so without this supplement
# Prometheus never gets a StatefulSet and the k8ssandra-operator's reconcile
# aborts at telemetry — taking Reaper down with it.
echo "    Applying OpenShift finalizers RBAC supplement..."
kubectl apply -f "$OCP_DIR/rbac-finalizers.yaml"
kubectl rollout restart deployment/kps-kube-prometheus-stack-operator -n monitoring 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 4: k8ssandra-operator
#
# cass-operator detects OpenShift automatically (openshift.mode defaults to
# auto) and omits runAsUser/runAsGroup so restricted-v2 can assign the
# namespace UID range. No anyuid grant should be needed.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 4/8: Installing k8ssandra-operator ($K8SSANDRA_OPERATOR_VERSION)..."
helm repo add k8ssandra https://helm.k8ssandra.io/stable 2>/dev/null || true
helm repo update k8ssandra >/dev/null
if helm status k8ssandra-operator -n "$NAMESPACE" &>/dev/null; then
  echo "    k8ssandra-operator already installed, skipping."
else
  helm install k8ssandra-operator k8ssandra/k8ssandra-operator \
    --namespace "$NAMESPACE" \
    --version "$K8SSANDRA_OPERATOR_VERSION" \
    --wait --timeout 5m
fi

# ---------------------------------------------------------------------------
# Step 5: Medusa bucket (NooBaa ObjectBucketClaim)
#
# Replaces the AWS S3 bucket + IRSA role the EKS path needs. The OBC produces a
# ConfigMap (bucket name/host/port) and a Secret (AWS-style key pair). Medusa
# wants a single `credentials` key in INI format, so we translate.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 5/8: Provisioning Medusa's backup bucket via NooBaa..."
kubectl apply -f "$OCP_DIR/medusa-obc.yaml"

echo "    Waiting for the ObjectBucketClaim to be Bound..."
for i in $(seq 1 60); do
  OBC_PHASE=$(kubectl get objectbucketclaim medusa-backups -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$OBC_PHASE" = "Bound" ] && break
  printf "    Waiting... (%ds)\r" $((i * 5))
  sleep 5
done
echo ""
if [ "${OBC_PHASE:-}" != "Bound" ]; then
  echo "ERROR: ObjectBucketClaim did not reach Bound (phase=${OBC_PHASE:-unknown})."
  echo "       Check NooBaa: kubectl get noobaa -n openshift-storage"
  exit 1
fi

BUCKET_NAME=$(kubectl get configmap medusa-backups -n "$NAMESPACE" -o jsonpath='{.data.BUCKET_NAME}')
AWS_KEY=$(kubectl get secret medusa-backups -n "$NAMESPACE" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
AWS_SECRET=$(kubectl get secret medusa-backups -n "$NAMESPACE" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
echo "    Bucket: $BUCKET_NAME"

# Medusa reads an INI-format `credentials` key, not AWS_* env-style keys.
kubectl create secret generic medusa-bucket-key \
  -n "$NAMESPACE" \
  --from-literal=credentials="[default]
aws_access_key_id = $AWS_KEY
aws_secret_access_key = $AWS_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "    Secret medusa-bucket-key written."

# ---------------------------------------------------------------------------
# Step 6: K8ssandraCluster
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 6/8: Deploying Cassandra cluster..."
# The bucket name is generated by the OBC, so it cannot be committed in the
# manifest. Render rather than mutate, so the working tree stays clean.
sed "s/REPLACE_WITH_OBC_BUCKET/$BUCKET_NAME/" \
  "$OCP_DIR/k8ssandra-cluster.yaml" > "$RENDERED_CR"
kubectl apply -f "$RENDERED_CR"

echo "    Waiting for CassandraDatacenter/dc1 to be Ready."
echo "    Bootstraps are serial — budget ~2-2.5 min per node."
(
  while true; do
    sleep 30
    kubectl get pods -l app.kubernetes.io/name=cassandra -n "$NAMESPACE" \
      -o custom-columns='POD:.metadata.name,RACK:.metadata.labels.cassandra\.datastax\.com/rack,READY:.status.containerStatuses[*].ready' \
      --no-headers 2>/dev/null | sed 's/^/      /' || true
    echo "      ---"
  done
) &
TICKER=$!
trap 'kill $TICKER 2>/dev/null || true' EXIT

DC_OK=true
kubectl wait --for=condition=Ready cassandradatacenter/dc1 -n "$NAMESPACE" --timeout=2400s || DC_OK=false

kill $TICKER 2>/dev/null || true
trap - EXIT

if [ "$DC_OK" != true ]; then
  echo ""
  echo "    ERROR: CassandraDatacenter/dc1 is not Ready."
  # The K8ssandraCluster's status.error carries webhook rejections verbatim, and
  # those never produce a CassandraDatacenter at all — so `kubectl describe
  # cassandradatacenter` shows nothing and the real reason is easy to miss.
  CR_ERR=$(kubectl get k8ssandracluster demo -n "$NAMESPACE" -o jsonpath='{.status.error}' 2>/dev/null || true)
  if [ -n "$CR_ERR" ]; then
    echo "    K8ssandraCluster reports:"
    echo "      $CR_ERR"
  else
    echo "    Check: kubectl describe cassandradatacenter dc1 -n $NAMESPACE"
    echo "           kubectl logs deployment/k8ssandra-operator -n $NAMESPACE --tail=100"
  fi
fi

echo ""
echo "    Rack balance:"
kubectl get pods -l app.kubernetes.io/name=cassandra -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.labels.cassandra\.datastax\.com/rack}{"\n"}{end}' \
  | sort | uniq -c | sed 's/^/      /'

# ---------------------------------------------------------------------------
# Step 7: easy-cass-mcp + NoSQLBench + Routes
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 7/8: Deploying easy-cass-mcp, NoSQLBench and Routes..."
kubectl apply -f "$MANIFESTS_DIR/apps/easy-cass-mcp-deployment.yaml"
kubectl apply -f "$OCP_DIR/easy-cass-mcp-service.yaml"
kubectl apply -f "$MANIFESTS_DIR/loadtest/nosqlbench-payments-configmap.yaml"
kubectl apply -f "$OCP_DIR/routes.yaml"

kubectl wait --for=condition=available deployment/easy-cass-mcp \
  -n "$NAMESPACE" --timeout=180s 2>/dev/null || echo "    (Deployment still progressing)"

# easy-cass-mcp often starts before the superuser secret is usable and then sits
# there logging "Bad credentials". Restarting once is cheaper than debugging it.
echo "    Restarting easy-cass-mcp to pick up superuser credentials..."
kubectl rollout restart deployment/easy-cass-mcp -n "$NAMESPACE"
kubectl rollout status deployment/easy-cass-mcp -n "$NAMESPACE" --timeout=3m || true

# ---------------------------------------------------------------------------
# Step 8: Summary
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 8/8: Collecting endpoints..."
MCP_HOST=$(kubectl get route easy-cass-mcp -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
REAPER_HOST=$(kubectl get route reaper -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
GRAFANA_HOST=$(kubectl get route grafana -n monitoring -o jsonpath='{.spec.host}' 2>/dev/null || true)

echo ""
echo "============================================"
if [ "$DC_OK" = true ]; then
  echo "  Deployment Complete!"
else
  echo "  Deployment FINISHED WITH ERRORS — see above"
fi
echo "============================================"
echo ""
echo "Cassandra superuser credentials:"
echo "  Username: $(kubectl get secret demo-superuser -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || echo '<not yet available>')"
echo "  Password: $(kubectl get secret demo-superuser -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo '<not yet available>')"
echo ""
[ -n "$GRAFANA_HOST" ] && echo "Grafana:  https://$GRAFANA_HOST  (admin / $GRAFANA_PASSWORD)"
[ -n "$REAPER_HOST" ]  && echo "Reaper:   https://$REAPER_HOST/webui/index.html"
echo ""
echo "Medusa bucket: $BUCKET_NAME (NooBaa, in-cluster)"
echo "  kubectl apply -f $OCP_DIR/../cassandra/medusa-backup-job.yaml"
echo ""
echo "Load test (two stages):"
echo "  kubectl apply -f $MANIFESTS_DIR/loadtest/nosqlbench-payments-prepare-job.yaml"
echo "  kubectl apply -f $MANIFESTS_DIR/loadtest/nosqlbench-payments-job.yaml"
echo ""

if [ -n "$MCP_HOST" ]; then
  echo "easy-cass-mcp endpoint:"
  echo "  https://$MCP_HOST/mcp/"
  echo ""
  # Edge TLS means this is real https — no --allow-http needed, unlike the
  # plain-HTTP NLB the EKS profile produced.
  MCP_JSON="$SCRIPT_DIR/../.mcp.json"
  cat > "$MCP_JSON" <<EOF
{
  "mcpServers": {
    "easy-cass-mcp": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "https://$MCP_HOST/mcp/"
      ]
    }
  }
}
EOF
  echo ".mcp.json updated with the Route hostname."
  echo "Restart Claude Code to reconnect easy-cass-mcp."
  echo ""
  echo "NOTE: claude_desktop_config.json is NOT updated automatically."
else
  echo "Route not ready. Check: kubectl get route -n $NAMESPACE"
fi
echo ""

[ "$DC_OK" = true ] || exit 1

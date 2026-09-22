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
# Step 5: Medusa's S3 endpoint (MinIO on Ceph RBD)
#
# NOT NooBaa. ODF offers S3 via Ceph RGW or NooBaa (MCG); this cluster's ODF is
# in EXTERNAL mode and exposes no RGW, and NooBaa's pv-pool agents are pinned at
# 400Mi by its operator -- OOMKilled ~75s into a full backup of a loaded ring,
# with three mitigations measured and all failed. See docs/TROUBLESHOOTING.md.
#
# MinIO gives the same properties (in-cluster, no AWS, no IAM ticket,
# s3_compatible) with limits we control.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 5/8: Deploying MinIO as Medusa's S3 endpoint..."

# The root credential is generated here, never committed. An existing secret is
# reused so re-running the script does not orphan the password MinIO already
# wrote its data under.
if kubectl get secret minio-root -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "    Reusing existing minio-root secret."
else
  MINIO_PASS_GEN="${MINIO_PASSWORD:-$(openssl rand -hex 24)}"
  kubectl create secret generic minio-root -n "$NAMESPACE" \
    --from-literal=MINIO_ROOT_USER="${MINIO_USER_NAME:-medusa}" \
    --from-literal=MINIO_ROOT_PASSWORD="$MINIO_PASS_GEN"
  echo "    Generated minio-root credentials."
fi

kubectl apply -f "$OCP_DIR/minio.yaml"

echo "    Waiting for MinIO to become ready..."
kubectl wait --for=condition=available deployment/minio \
  -n "$NAMESPACE" --timeout=300s || {
  echo "ERROR: MinIO did not become available."
  echo "       Check: kubectl get pods -n $NAMESPACE -l app=minio"
  exit 1
}

MINIO_USER=$(kubectl get secret minio-root -n "$NAMESPACE" -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)
MINIO_PASS=$(kubectl get secret minio-root -n "$NAMESPACE" -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)
BUCKET_NAME="medusa-backups"

# Create the bucket. Medusa does not create it for you, and a missing bucket
# surfaces as an opaque 403 on HeadObject rather than anything obvious.
echo "    Creating bucket $BUCKET_NAME..."
# Create, then VERIFY SEPARATELY. `kubectl run --rm -i` races its own pod
# deletion against log streaming, so its exit code and stdout are not a reliable
# signal -- an earlier version reported failure on a bucket that had in fact
# been created. Trust `mc ls`, not the creating command.
mc_run() {
  kubectl run "minio-mc-$1-$$" --rm -i --restart=Never -n "$NAMESPACE" \
    --image=quay.io/minio/mc:latest --command -- sh -c "
      mc alias set local http://minio.$NAMESPACE.svc.cluster.local:9000 '$MINIO_USER' '$MINIO_PASS' >/dev/null 2>&1
      $2" 2>/dev/null
}
mc_run mb "mc mb --ignore-existing local/$BUCKET_NAME >/dev/null 2>&1" >/dev/null || true
if mc_run ls "mc ls local/ 2>/dev/null" | grep -q "$BUCKET_NAME"; then
  echo "    Bucket ready: $BUCKET_NAME"
else
  echo "    WARNING: bucket $BUCKET_NAME not found after creation attempt."
  echo "             Medusa will fail on first backup. Check: kubectl logs deploy/minio -n $NAMESPACE"
fi

# Medusa reads an INI-format `credentials` key, not AWS_*-style env vars.
kubectl create secret generic medusa-minio-key \
  -n "$NAMESPACE" \
  --from-literal=credentials="[default]
aws_access_key_id = $MINIO_USER
aws_secret_access_key = $MINIO_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "    Secret medusa-minio-key written."

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
# `kubectl wait` ERRORS IMMEDIATELY on a resource that does not exist yet -- it
# does not wait for it to appear. The operator needs a moment to reconcile the
# K8ssandraCluster into a CassandraDatacenter, so waiting for Ready straight
# away fails with "dc1 not found" on a perfectly healthy deploy.
for _ in $(seq 1 60); do
  kubectl get cassandradatacenter dc1 -n "$NAMESPACE" >/dev/null 2>&1 && break
  sleep 5
done
kubectl wait --for=condition=Ready cassandradatacenter/dc1 -n "$NAMESPACE" --timeout=2400s || DC_OK=false

kill $TICKER 2>/dev/null || true
trap - EXIT

# ---------------------------------------------------------------------------
# Reaper's schema-init init-container crash-loops on a FRESH cluster.
#
# It applies ~34 CQL migration scripts, and its driver gives up waiting for
# schema agreement after ~2s. On a newly-built ring each DDL takes longer than
# that, so the container dies partway through script 034. The statements are
# CREATE TABLE IF NOT EXISTS, so every restart gets FURTHER than the last --
# it is genuinely making progress, not looping uselessly.
#
# The problem is Kubernetes' exponential backoff: by the 6th restart it is
# waiting ~5 minutes between attempts, so "self-healing" takes the better part
# of an hour. Deleting the pod resets the backoff timer and it finishes in two
# or three quick attempts.
#
# MEASURED 22 Sep on a fresh deploy: crash-looped at 11 reaper_db tables with a
# 5-minute backoff; two forced deletes took it to 19 tables and Running in
# under three minutes.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Nudging Reaper through its schema migration..."
for _ in $(seq 1 12); do
  RP=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -- '-reaper-' | awk '{print $1}' | head -1)
  [ -z "$RP" ] && { sleep 20; continue; }
  RS=$(kubectl get pod "$RP" -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}')
  case "$RS" in
    Running) echo "    Reaper is up."; break ;;
    Init:CrashLoopBackOff|Init:Error)
      echo "    Reaper in $RS — resetting backoff (this is expected on a fresh cluster)."
      kubectl delete pod "$RP" -n "$NAMESPACE" --grace-period=0 --force >/dev/null 2>&1 || true ;;
    *) : ;;
  esac
  sleep 25
done
if ! kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -- '-reaper-' | grep -q Running; then
  echo "    WARNING: Reaper did not reach Running. Repairs will not work."
  echo "             Retry: kubectl delete pod -l app.kubernetes.io/name=reaper -n $NAMESPACE"
fi

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

# ---------------------------------------------------------------------------
# easy-cass-mcp hot-patch.
#
# The published image's get_compaction_strategy() tests `isinstance(opts, dict)`,
# but the Python driver hands back CQL maps as OrderedMapSerializedKey -- a
# Mapping, NOT a dict. The test therefore fails for every table, every table is
# reported as SizeTieredCompactionStrategy, and analyze_table_optimizations
# cheerfully advises UCS tables to "switch to UCS".
#
# That tool is demoed in the talk, and the failure is silent: confident, wrong
# advice rather than an error. So the patch is applied on every deploy, not by
# hand afterwards. patches/easy-cass-mcp/apply.sh mounts a corrected
# cassandra_table.py over the image's copy via ConfigMap; it is idempotent and
# has a `rollback` mode.
# ---------------------------------------------------------------------------
ECM_PATCH="$SCRIPT_DIR/../patches/easy-cass-mcp/apply.sh"
if [ -x "$ECM_PATCH" ]; then
  echo "    Applying easy-cass-mcp compaction-strategy patch..."
  # apply.sh ends with `kubectl rollout status`, which times out while the
  # deployment is mid-restart from the credentials rollout above -- a non-zero
  # exit even though the ConfigMap and volumeMount landed correctly. Verify the
  # mount instead of trusting the exit code.
  "$ECM_PATCH" >/dev/null 2>&1 || true
  if kubectl get deploy easy-cass-mcp -n "$NAMESPACE" \
       -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null | grep -q ecm-patch; then
    echo "    Patch applied."
  else
    echo "    WARNING: easy-cass-mcp patch did NOT apply."
    echo "             analyze_table_optimizations will report every table as STCS."
    echo "             Retry by hand: $ECM_PATCH"
  fi
else
  echo "    WARNING: $ECM_PATCH not found or not executable — skipping."
  echo "             analyze_table_optimizations will report every table as STCS."
fi

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

# ---------------------------------------------------------------------------
# Grafana service account for the read-only Grafana MCP server.
#
# This MUST be minted on every deploy. The kube-prometheus-stack chart gives
# Grafana an emptyDir for its database, so service accounts and their tokens do
# not survive a pod restart -- including the `rollout restart` this very script
# performs in Step 3 to reload the Thanos datasource. A token created by hand
# will be silently dead the next time this runs.
#
# Viewer is deliberately the lowest role that works. Verified on Grafana 13:
# it can list datasources and query them through the datasource proxy, while
# dashboard-create, annotation-create and datasource-delete all return 403.
# ---------------------------------------------------------------------------
GRAFANA_TOKEN_FILE="$SCRIPT_DIR/../.grafana-mcp-token"
GRAFANA_MCP_OK=false
if [ -n "$GRAFANA_HOST" ]; then
  echo "    Minting a read-only Grafana service account for the MCP server..."
  GF_API="https://$GRAFANA_HOST"
  GF_AUTH="admin:$GRAFANA_PASSWORD"

  for _ in $(seq 1 30); do
    curl -sf --max-time 10 "$GF_API/api/health" >/dev/null 2>&1 && break
    sleep 5
  done

  # Idempotent: drop any previous account of this name so the token we write
  # is always the one that works.
  OLD_ID=$(curl -s --max-time 20 -u "$GF_AUTH" \
      "$GF_API/api/serviceaccounts/search?query=claude-mcp-readonly" 2>/dev/null \
      | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    a=[x for x in d.get("serviceAccounts",[]) if x.get("name")=="claude-mcp-readonly"]
    print(a[0]["id"] if a else "")
except Exception: print("")' 2>/dev/null || true)
  if [ -n "$OLD_ID" ]; then
    curl -s --max-time 20 -u "$GF_AUTH" -X DELETE \
      "$GF_API/api/serviceaccounts/$OLD_ID" >/dev/null 2>&1 || true
  fi

  SA_ID=$(curl -s --max-time 20 -u "$GF_AUTH" -H 'Content-Type: application/json' \
      -d '{"name":"claude-mcp-readonly","role":"Viewer","isDisabled":false}' \
      "$GF_API/api/serviceaccounts" 2>/dev/null \
      | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")' 2>/dev/null || true)

  if [ -n "$SA_ID" ]; then
    GF_TOKEN=$(curl -s --max-time 20 -u "$GF_AUTH" -H 'Content-Type: application/json' \
        -d '{"name":"claude-code-mcp"}' \
        "$GF_API/api/serviceaccounts/$SA_ID/tokens" 2>/dev/null \
        | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("key",""))
except Exception: print("")' 2>/dev/null || true)
    if [ -n "$GF_TOKEN" ]; then
      printf '%s' "$GF_TOKEN" > "$GRAFANA_TOKEN_FILE"
      chmod 600 "$GRAFANA_TOKEN_FILE"
      GRAFANA_MCP_OK=true
      echo "    Wrote .grafana-mcp-token (gitignored, Viewer role)."
    fi
  fi

  if [ "$GRAFANA_MCP_OK" != true ]; then
    echo "    WARNING: could not mint a Grafana service-account token."
    echo "             The grafana MCP server will fail to authenticate."
  fi
fi

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
echo "Medusa S3: MinIO in-cluster — bucket $BUCKET_NAME (minio.$NAMESPACE.svc:9000)"
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
  # NOTE: this file is REWRITTEN, not merged. Both servers must be emitted here
  # or a redeploy silently removes whichever one is left out.
  MCP_GRAFANA_BIN="${MCP_GRAFANA_BIN:-$HOME/.local/bin/mcp-grafana}"
  if [ "$GRAFANA_MCP_OK" = true ] && [ -x "$MCP_GRAFANA_BIN" ]; then
    cat > "$MCP_JSON" <<EOF
{
  "mcpServers": {
    "easy-cass-mcp": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "https://$MCP_HOST/mcp/"
      ]
    },
    "grafana": {
      "command": "$MCP_GRAFANA_BIN",
      "args": [
        "--disable-write",
        "--enabled-tools",
        "search,datasource,prometheus,dashboard,navigation"
      ],
      "env": {
        "GRAFANA_URL": "https://$GRAFANA_HOST",
        "GRAFANA_SERVICE_ACCOUNT_TOKEN_FILE": "$(cd "$SCRIPT_DIR/.." && pwd)/.grafana-mcp-token"
      }
    }
  }
}
EOF
    echo ".mcp.json updated: easy-cass-mcp + grafana (read-only)."
  else
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
    echo ".mcp.json updated with the Route hostname (grafana MCP omitted)."
    [ -x "$MCP_GRAFANA_BIN" ] || echo "  (mcp-grafana not found at $MCP_GRAFANA_BIN)"
  fi
  echo ""
  echo "RESTART CLAUDE CODE before doing anything else."
  echo "  - easy-cass-mcp: the Route hostname above is new to this session."
  echo "  - grafana: mcp-grafana reads the service-account token ONCE at"
  echo "    startup, not per request. This deploy just minted a NEW token, so"
  echo "    an already-running server will return 401 Unauthorized on every"
  echo "    call until it is restarted. Verified: the token is valid via curl"
  echo "    while the running server still rejects it."
  echo ""
  echo "NOTE: claude_desktop_config.json is NOT updated automatically."
else
  echo "Route not ready. Check: kubectl get route -n $NAMESPACE"
fi
echo ""

[ "$DC_OK" = true ] || exit 1

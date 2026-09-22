#!/bin/bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "  K8ssandra Workshop - OpenShift Teardown"
echo "============================================"
echo ""
echo "This will delete ALL workshop resources."
echo "Current kubectl context: $(kubectl config current-context)"
echo "Namespace: $NAMESPACE"
echo ""
read -p "Are you sure? (yes/no) " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 1
fi

echo ""
echo ">>> Deleting NoSQLBench jobs..."
kubectl delete job -l app=nosqlbench -n "$NAMESPACE" --ignore-not-found
# The `payments` keyspace lives inside Cassandra and goes away with the
# K8ssandraCluster below; only the workload ConfigMap needs removing here.
kubectl delete configmap nb-cql-payments -n "$NAMESPACE" --ignore-not-found
# nb-cql-keyvalue is the pre-payments workload; it lingers on clusters built
# before the switch. easy-cass-mcp-patch is the compaction-strategy hot-patch
# applied by deploy Step 7 — orphaned once the deployment is gone.
kubectl delete configmap nb-cql-keyvalue easy-cass-mcp-patch -n "$NAMESPACE" --ignore-not-found

echo ""
echo ">>> Deleting Routes..."
kubectl delete route easy-cass-mcp reaper -n "$NAMESPACE" --ignore-not-found
kubectl delete route grafana -n monitoring --ignore-not-found

echo ""
echo ">>> Deleting easy-cass-mcp..."
kubectl delete svc easy-cass-mcp -n "$NAMESPACE" --ignore-not-found
kubectl delete deployment easy-cass-mcp -n "$NAMESPACE" --ignore-not-found

echo ""
echo ">>> Deleting Medusa backup objects..."
kubectl delete medusabackupjob --all -n "$NAMESPACE" --ignore-not-found
kubectl delete medusabackup --all -n "$NAMESPACE" --ignore-not-found
kubectl delete medusabackupschedule --all -n "$NAMESPACE" --ignore-not-found

echo ""
echo ">>> Deleting K8ssandraCluster (this also removes Reaper)..."
kubectl delete k8ssandracluster demo -n "$NAMESPACE" --ignore-not-found --timeout=180s

echo ""
echo ">>> Deleting Cassandra PVCs..."
kubectl delete pvc -l cassandra.datastax.com/cluster=demo -n "$NAMESPACE" --ignore-not-found

echo ""
echo ">>> Deleting MinIO and the Medusa bucket..."
# MinIO's PVC holds every backup. Unlike the EKS path there is no out-of-band
# S3 bucket to preserve — it all lives here, and it all goes.
kubectl delete deployment minio -n "$NAMESPACE" --ignore-not-found
kubectl delete service minio -n "$NAMESPACE" --ignore-not-found
kubectl delete pvc minio-data -n "$NAMESPACE" --ignore-not-found
kubectl delete secret medusa-minio-key minio-root -n "$NAMESPACE" --ignore-not-found

echo ""
echo ">>> Uninstalling k8ssandra-operator..."
helm uninstall k8ssandra-operator -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo ""
echo ">>> Uninstalling kube-prometheus-stack..."
helm uninstall kps -n monitoring --ignore-not-found 2>/dev/null || true
kubectl delete pvc -l app.kubernetes.io/name=prometheus -n monitoring --ignore-not-found
kubectl delete namespace monitoring --ignore-not-found

echo ""
echo ">>> Uninstalling cert-manager..."
helm uninstall cert-manager -n cert-manager --ignore-not-found 2>/dev/null || true
kubectl delete namespace cert-manager --ignore-not-found

echo ""
echo ">>> Deleting CRDs installed by this workshop..."
# Scoped BY API GROUP, deliberately. Do NOT broaden this to a name match:
#   - monitoring.coreos.com/* belongs to OpenShift's cluster-version-operator.
#     kube-prometheus-stack is installed here with --skip-crds precisely because
#     those CRDs are not ours. Deleting them breaks cluster monitoring.
#   - objectbucket.io/* belongs to ODF.
# Everything listed below was installed by cert-manager or k8ssandra-operator.
for grp in \
  k8ssandra.io \
  cassandra.datastax.com \
  medusa.k8ssandra.io \
  reaper.k8ssandra.io \
  control.k8ssandra.io \
  config.k8ssandra.io \
  replication.k8ssandra.io \
  stargate.k8ssandra.io \
  cert-manager.io \
  acme.cert-manager.io
do
  CRDS=$(kubectl get crd -o name 2>/dev/null | grep -E "\.${grp}$" || true)
  if [ -n "$CRDS" ]; then
    echo "    $grp"
    echo "$CRDS" | xargs -r kubectl delete --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
  fi
done

echo ""
echo ">>> Removing node labels and the loadgen taint..."
# Mirrors manifests/openshift/node-labels.sh. Without this the cluster is not
# actually back to its delivered state — and a stray k8ssandra.io/rack label on
# a node that is later reused will silently affect rack placement.
for n in $(kubectl get nodes -l workload -o name 2>/dev/null); do
  kubectl label "$n" workload- k8ssandra.io/rack- >/dev/null 2>&1 || true
done
LOADGEN_NODE="${LOADGEN_NODE:-itz-ckzpiv-worker-4}"
kubectl taint node "$LOADGEN_NODE" workload=loadgen:NoSchedule- >/dev/null 2>&1 || true
kubectl get nodes -L workload,k8ssandra.io/rack

echo ""
echo "NOT removed, on purpose:"
echo "  - github-ibm-pat secret in default — TechZone's Tekton credential, not ours"
echo "  - monitoring.coreos.com and objectbucket.io CRDs — owned by OpenShift/ODF"
echo "  - NooBaa backing store is left at numVolumes=3. It was raised from 1 while"
echo "    diagnosing Medusa and NooBaa cannot scale a pv-pool DOWN, so three 50Gi"
echo "    PVCs remain in openshift-storage. Harmless, but it is a one-way change."

echo ""
echo "============================================"
echo "  Teardown Complete!"
echo "============================================"
echo ""
echo "Node labels and the loadgen taint are left in place — they are cheap to"
echo "keep and re-running the deploy needs them. To remove them:"
echo "  kubectl label nodes --all workload- k8ssandra.io/rack-"
echo "  kubectl taint nodes -l workload=loadgen workload=loadgen:NoSchedule-"
echo ""
echo "The OpenShift cluster itself is provisioned by IBM TechZone — release the"
echo "reservation through the portal."
echo ""

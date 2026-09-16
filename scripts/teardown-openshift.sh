#!/bin/bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

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
echo ">>> Deleting the Medusa bucket..."
# Deleting the OBC deletes the NooBaa bucket and its contents. Unlike the EKS
# path there is no out-of-band S3 bucket to preserve — it all lives here.
kubectl delete objectbucketclaim medusa-backups -n "$NAMESPACE" --ignore-not-found
kubectl delete secret medusa-bucket-key -n "$NAMESPACE" --ignore-not-found

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

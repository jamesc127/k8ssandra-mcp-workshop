#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  K8ssandra Workshop - Teardown"
echo "============================================"
echo ""
echo "This will delete ALL workshop resources."
echo "Current kubectl context: $(kubectl config current-context)"
echo ""
read -p "Are you sure? (yes/no) " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 1
fi

echo ""
echo ">>> Deleting NoSQLBench jobs..."
kubectl delete job -l app=nosqlbench -n default --ignore-not-found
# The `payments` keyspace lives inside Cassandra and goes away with the
# K8ssandraCluster below; only the workload ConfigMap needs removing here.
kubectl delete configmap nb-cql-payments -n default --ignore-not-found

echo ""
echo ">>> Deleting easy-cass-mcp..."
kubectl delete svc easy-cass-mcp -n default --ignore-not-found
kubectl delete deployment easy-cass-mcp -n default --ignore-not-found

echo ""
echo ">>> Deleting Medusa backup objects..."
kubectl delete medusabackupjob --all -n default --ignore-not-found
kubectl delete medusabackup --all -n default --ignore-not-found
kubectl delete medusabackupschedule --all -n default --ignore-not-found

echo ""
echo ">>> Deleting K8ssandraCluster (this also removes Reaper)..."
kubectl delete k8ssandracluster demo -n default --ignore-not-found --timeout=120s

echo ""
echo ">>> Waiting for Cassandra PVCs to be cleaned up..."
kubectl delete pvc -l cassandra.datastax.com/cluster=demo -n default --ignore-not-found

echo ""
echo ">>> Uninstalling k8ssandra-operator..."
helm uninstall k8ssandra-operator -n default --ignore-not-found 2>/dev/null || true

echo ""
echo ">>> Uninstalling kube-prometheus-stack..."
helm uninstall kps -n monitoring --ignore-not-found 2>/dev/null || true
# The Prometheus StatefulSet PVC is not removed by helm uninstall.
kubectl delete pvc -l app.kubernetes.io/name=prometheus -n monitoring --ignore-not-found
kubectl delete namespace monitoring --ignore-not-found

echo ""
echo ">>> Uninstalling metrics-server..."
helm uninstall metrics-server -n kube-system --ignore-not-found 2>/dev/null || true

echo ""
echo ">>> Uninstalling cert-manager..."
helm uninstall cert-manager -n cert-manager --ignore-not-found 2>/dev/null || true
kubectl delete namespace cert-manager --ignore-not-found

echo ""
echo ">>> Deleting StorageClass..."
kubectl delete storageclass ebs-gp3 --ignore-not-found

echo ""
echo "============================================"
echo "  Teardown Complete!"
echo "============================================"
echo ""
echo "The EKS cluster itself is provisioned out-of-band by the portal — do NOT"
echo "run 'eksctl delete cluster'. Release the reservation through the portal."
echo ""
echo "Medusa's S3 bucket and IAM role are also out-of-band and are left intact."
echo "To remove them, see manifests/infra/medusa-irsa.md (Teardown section)."
echo ""

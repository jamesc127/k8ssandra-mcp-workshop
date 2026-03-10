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
kubectl delete configmap nb-cql-keyvalue -n default --ignore-not-found

echo ""
echo ">>> Deleting easy-cass-mcp..."
kubectl delete svc easy-cass-mcp -n default --ignore-not-found
kubectl delete deployment easy-cass-mcp -n default --ignore-not-found

echo ""
echo ">>> Deleting K8ssandraCluster..."
kubectl delete k8ssandracluster demo -n default --ignore-not-found --timeout=120s

echo ""
echo ">>> Waiting for Cassandra PVCs to be cleaned up..."
kubectl delete pvc -l cassandra.datastax.com/cluster=demo -n default --ignore-not-found

echo ""
echo ">>> Uninstalling k8ssandra-operator..."
helm uninstall k8ssandra-operator -n default --ignore-not-found 2>/dev/null || true

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
echo "To delete the EKS cluster itself:"
echo "  eksctl delete cluster --name k8ssandra-cluster --region us-east-1"
echo ""

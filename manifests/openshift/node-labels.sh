#!/bin/bash
# Label and taint the OpenShift worker nodes for the workshop layout.
#
# On EKS this is done declaratively in the eksctl ClusterConfig. This OpenShift
# cluster is provisioned by IBM TechZone with no node-group configuration
# available to us, so the same result is applied imperatively here.
#
#   3 workers -> Cassandra, one synthetic rack each
#   1 worker  -> load generator, TAINTED so nothing else lands on it
#   1 worker  -> utility (Prometheus, Grafana, Reaper, operators, MCP)
#
# WHY SYNTHETIC RACKS: this cluster has no topology.kubernetes.io/zone labels at
# all — every node is in one datacenter. Rack-per-AZ is therefore impossible.
# Racks in Cassandra are a *logical* failure domain, so we map them to nodes
# instead. Three racks is the requirement that matters: Cassandra's default
# allocate_tokens_for_local_replication_factor=3 needs 3 racks to allocate
# tokens, and with fewer the bootstrap stalls.
set -euo pipefail

CASSANDRA_NODES=("${CASSANDRA_NODES:-itz-ckzpiv-worker-1 itz-ckzpiv-worker-2 itz-ckzpiv-worker-3}")
LOADGEN_NODE="${LOADGEN_NODE:-itz-ckzpiv-worker-4}"
UTILITY_NODE="${UTILITY_NODE:-itz-ckzpiv-worker-5}"

read -r -a CASS <<< "${CASSANDRA_NODES[*]}"

if [ "${#CASS[@]}" -ne 3 ]; then
  echo "ERROR: exactly 3 Cassandra nodes are required (got ${#CASS[@]})."
  echo "       Three racks are needed for the token allocator."
  exit 1
fi

echo ">>> Labelling Cassandra nodes (one rack each)..."
for i in 0 1 2; do
  rack="rack$((i + 1))"
  echo "    ${CASS[$i]} -> workload=cassandra, rack=$rack"
  kubectl label node "${CASS[$i]}" workload=cassandra --overwrite
  kubectl label node "${CASS[$i]}" k8ssandra.io/rack="$rack" --overwrite
done

echo ">>> Labelling and tainting the load generator node..."
# The taint is what actually reserves the node. A label alone does not repel
# pods, and soft anti-affinity silently no-ops once every node is occupied —
# which is exactly what inflated p50 read latency 3-4x in an earlier run.
kubectl label node "$LOADGEN_NODE" workload=loadgen --overwrite
kubectl taint node "$LOADGEN_NODE" workload=loadgen:NoSchedule --overwrite

echo ">>> Labelling the utility node..."
kubectl label node "$UTILITY_NODE" workload=utility --overwrite

echo ""
echo ">>> Result:"
kubectl get nodes -L workload,k8ssandra.io/rack

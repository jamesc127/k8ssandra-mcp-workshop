#!/usr/bin/env bash
# Hot-patch easy-cass-mcp on OpenShift: mount the fixed ecm/cassandra_table.py
# over the one in rustyrazorblade/easy-cass-mcp:latest via a ConfigMap.
#
# Fix: get_compaction_strategy() checked isinstance(..., dict), but the Python
# driver returns CQL maps as OrderedMapSerializedKey (a Mapping, not a dict),
# so every table was reported as STCS and UCS tables were told to "switch to UCS".
#
# Usage:  ./apply.sh            # apply patch + roll out
#         ./apply.sh rollback   # remove patch, back to stock image file
set -euo pipefail
cd "$(dirname "$0")"
NS=default
DEPLOY=easy-cass-mcp
CM=easy-cass-mcp-patch

if [[ "${1:-}" == "rollback" ]]; then
  kubectl -n "$NS" patch deploy "$DEPLOY" --type=json -p='[
    {"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts"},
    {"op":"remove","path":"/spec/template/spec/volumes"}]'
  kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s
  kubectl -n "$NS" delete configmap "$CM" --ignore-not-found
  exit 0
fi

kubectl -n "$NS" create configmap "$CM" \
  --from-file=cassandra_table.py=cassandra_table.py \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" patch deploy "$DEPLOY" --type=json -p='[
  {"op":"add","path":"/spec/template/spec/volumes","value":[
    {"name":"ecm-patch","configMap":{"name":"'"$CM"'"}}]},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts","value":[
    {"name":"ecm-patch","mountPath":"/app/ecm/cassandra_table.py","subPath":"cassandra_table.py","readOnly":true}]}]'

kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s
POD=$(kubectl -n "$NS" get pod -l app="$DEPLOY" -o name | head -1)
echo "Patched file in pod:"
kubectl -n "$NS" exec "$POD" -- grep -n "Mapping" /app/ecm/cassandra_table.py

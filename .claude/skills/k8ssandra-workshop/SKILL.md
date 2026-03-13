---
name: k8ssandra-workshop
description: >
  Use this skill whenever the user asks about deploying, managing, monitoring,
  scaling, load testing, or tearing down the K8ssandra on EKS workshop
  environment. Trigger on any request involving: EKS cluster creation, eksctl,
  k8ssandra-operator, K8ssandraCluster, Cassandra pods, easy-cass-mcp, NLB
  endpoint, Claude Desktop MCP config, NoSQLBench load tests, Cassandra
  credentials, or workshop teardown. Use kubectl/helm/aws Bash commands for
  Kubernetes-level operations. Use easy-cass-mcp MCP tools for all
  Cassandra-specific operations (CQL queries, schema inspection, nodetool
  equivalents, config recommendations). This skill takes precedence over the
  cassandra-k8s-deploy skill for any work in this repository.
---

# K8ssandra Workshop Skill

All commands run from the repo root. Everything lives in the `default` namespace.
Cluster name: `k8ssandra-cluster`, region: `us-east-1` (override via `CLUSTER_NAME` / `REGION` env vars).

---

## Tool Selection Guide

**Use `kubectl`/`helm`/`aws` (Bash) for:**
- Pod/deployment/service lifecycle (apply, delete, wait, rollout)
- Scaling the K8ssandraCluster CR
- Checking operator status, logs, events
- Load test (NoSQLBench job) management
- EKS cluster creation/teardown

**Use `easy-cass-mcp` MCP tools for:**
- CQL queries against keyspaces and tables
- Schema inspection (`get_keyspaces`, `get_tables`, `get_create_table`)
- Cluster topology and node status (`query_system_table` with `local` or `peers_v2`)
- Compaction history, token ranges, size estimates (system table queries)
- Table optimization analysis (`analyze_table_optimizations`)
- Config recommendations (`get_config_recommendations`)

**Available easy-cass-mcp tools:**

| Tool | Purpose | nodetool equivalent |
|---|---|---|
| `get_keyspaces` | List all keyspaces | — |
| `get_tables` | List tables in a keyspace | — |
| `get_create_table` | DESCRIBE a table | — |
| `query_system_table` | Query system keyspace tables (peers, local, compaction_history, size_estimates, etc.) | `nodetool status`, `nodetool info`, `nodetool compactionhistory` |
| `query_all_nodes` | Run a CQL query on all nodes | `nodetool` broadcast queries |
| `query_node` | Run a CQL query on a specific node | — |
| `analyze_table_optimizations` | Compaction strategy and table optimization suggestions | `nodetool tablestats` |
| `get_config_recommendations` | Config recommendations based on Cassandra version | — |

> **Note:** The easy-cass-mcp endpoint is configured in `.mcp.json`. After adding or changing the NLB hostname there, restart Claude Code to pick up the new connection.

---

## 1. Prerequisites Check

```bash
for cmd in kubectl helm aws eksctl; do
  command -v $cmd && echo "$cmd: OK" || echo "$cmd: MISSING"
done
kubectl config current-context
```

---

## 2. EKS Cluster Creation (~15 min, one-time)

```bash
eksctl create cluster -f manifests/infra/eksctl-cluster.yaml
```

Provisions: VPC + auto-tagged subnets, 3x `m5.xlarge` managed nodes (private subnets + NAT), EBS CSI addon with IRSA, OIDC provider.

Update kubeconfig after completion:
```bash
aws eks update-kubeconfig --name k8ssandra-cluster --region us-east-1
```

---

## 3. Full Stack Deploy

Run the orchestrated script (confirms kubectl context interactively):
```bash
./scripts/deploy.sh
```

Or step-by-step:

**Step 1 — StorageClass:**
```bash
kubectl apply -f manifests/infra/storageclass.yaml
```

**Step 2 — cert-manager:**
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --set crds.enabled=true --wait --timeout 5m
```

**Step 3 — k8ssandra-operator (must be `default` namespace):**
```bash
helm repo add k8ssandra https://helm.k8ssandra.io/stable
helm repo update k8ssandra
helm install k8ssandra-operator k8ssandra/k8ssandra-operator \
  --namespace default --wait --timeout 5m
```

**Step 4 — Cassandra cluster (~3-5 min):**
```bash
kubectl apply -f manifests/cassandra/k8ssandra-cluster.yaml
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=cassandra -n default --timeout=600s
```

**Step 5 — easy-cass-mcp + NoSQLBench ConfigMap:**
```bash
kubectl apply -f manifests/apps/easy-cass-mcp-deployment.yaml
kubectl apply -f manifests/apps/easy-cass-mcp-service.yaml
kubectl apply -f manifests/loadtest/nosqlbench-configmap.yaml
kubectl wait --for=condition=available deployment/easy-cass-mcp \
  -n default --timeout=120s
```

---

## 4. Health Monitoring

```bash
# All pods
kubectl get pods -n default

# Cassandra pods only
kubectl get pods -l app.kubernetes.io/name=cassandra -n default

# K8ssandraCluster status
kubectl get k8ssandracluster demo -n default -o yaml | grep -A 20 "status:"

# easy-cass-mcp
kubectl get deployment easy-cass-mcp -n default
kubectl logs deployment/easy-cass-mcp -n default --tail=50

# Node/pod resource usage
kubectl top nodes
kubectl top pods -n default
```

---

## 5. NLB Endpoint + Credentials (Claude Desktop Config)

```bash
# NLB hostname (may take 1-3 min after deploy)
kubectl get svc easy-cass-mcp -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Cassandra superuser credentials
echo "Username: $(kubectl get secret demo-superuser -n default \
  -o jsonpath='{.data.username}' | base64 -d)"
echo "Password: $(kubectl get secret demo-superuser -n default \
  -o jsonpath='{.data.password}' | base64 -d)"
```

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "cassandra": {
      "command": "npx",
      "args": ["mcp-remote", "http://<NLB_HOSTNAME>:8000/mcp/", "--allow-http"]
    }
  }
}
```

If `npx` is not in Claude Desktop's PATH:
```bash
sudo ln -sf $(which npx) /usr/local/bin/npx
```

---

## 6. Load Test Management

```bash
# Start 3-phase load test (schema → 500k rampup → 30min mixed 50/50 at 1000 ops/sec)
kubectl apply -f manifests/loadtest/nosqlbench-job.yaml

# Monitor progress
kubectl get job nosqlbench-load -n default
kubectl logs -f job/nosqlbench-load -n default

# Re-run (Jobs are immutable — must delete first)
kubectl delete job nosqlbench-load -n default
kubectl apply -f manifests/loadtest/nosqlbench-job.yaml

# Stop
kubectl delete job nosqlbench-load -n default
```

---

## 7. Scale Cassandra

```bash
# Scale to N nodes (currently 3)
kubectl patch k8ssandracluster demo -n default \
  --type=merge \
  -p '{"spec":{"cassandra":{"datacenters":[{"metadata":{"name":"dc1"},"size":N}]}}}'

# Watch the rollout
kubectl get pods -l app.kubernetes.io/name=cassandra -n default -w
```

---

## 8. Teardown

```bash
# Remove all workshop resources (keeps EKS cluster)
./scripts/teardown.sh

# Delete the EKS cluster itself (~10 min)
eksctl delete cluster --name k8ssandra-cluster --region us-east-1
```

---

## Troubleshooting Quick Reference

| Symptom | Likely Cause | First Check |
|---|---|---|
| NLB never gets hostname | Subnets missing LB tags | Was cluster created with `manifests/infra/eksctl-cluster.yaml`? |
| Webhook error on K8ssandraCluster | Operator in wrong namespace | `helm list -A` — should show `default` |
| easy-cass-mcp unreachable via NLB | FastMCP bound to 127.0.0.1 | `kubectl exec deployment/easy-cass-mcp -- env \| grep FASTMCP` |
| Claude Desktop "No such file" | Binary not in Claude's PATH | Symlink `npx`/`kubectl`/`aws` to `/usr/local/bin` |
| Cassandra pods Pending | Node/PVC issue | `kubectl describe pod <pod> -n default` |
| NoSQLBench fails to start | Wrong binary path | Must use `java -jar /nb5.jar`, not `nb5` |

For detailed diagnosis and remediation commands, see @references/troubleshooting.md.

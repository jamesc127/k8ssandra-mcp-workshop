# K8ssandra on EKS Workshop

## Project Overview

Workshop repo for teaching Apache Cassandra on Amazon EKS using k8ssandra-operator, with MCP-based AI tooling (easy-cass-mcp) for cluster management via Claude Desktop.

## Architecture

- **EKS** cluster with managed node groups (6x `m5.4xlarge` in private subnets; sized for 100k TPS load test and 3→6 Cassandra scale-up demo)
- **3-node Cassandra ring** (datacenter: `dc1`) managed by k8ssandra-operator, with `resources.requests` set (Burstable QoS) for noisy-neighbor protection
- **k8ssandra-operator** installed to `default` namespace (required for webhook alignment)
- **easy-cass-mcp** deployed in-cluster, exposed via internet-facing NLB on port 8000
- **cert-manager** handles TLS for operator webhooks
- **metrics-server** installed in `kube-system` for `kubectl top` node/pod metrics
- **NoSQLBench** provides on-demand CQL load testing (default: 1-hour run at 100k ops/sec) with pod anti-affinity to avoid Cassandra co-location

## Key Files

```
manifests/
  infra/eksctl-cluster.yaml             # EKS ClusterConfig (node groups, EBS CSI addon, OIDC)
  infra/storageclass.yaml               # EBS gp3 (ebs.csi.aws.com)
  cassandra/k8ssandra-cluster.yaml      # K8ssandraCluster CR (3 nodes default, 2G heap, 5Gi storage, 4-6 CPU / 3-6Gi req/limit, softPodAntiAffinity)
  apps/easy-cass-mcp-*.yaml             # MCP server deployment + NLB service
  loadtest/nosqlbench-*.yaml            # CQL key-value workload + Job
scripts/
  deploy.sh                            # Full 6-step orchestrated deployment
  teardown.sh                          # Reverse-order resource cleanup
docs/
  TROUBLESHOOTING.md                   # Known issues and fixes
```

## Critical Conventions

### EKS Cluster
- Cluster created via `eksctl create cluster -f manifests/infra/eksctl-cluster.yaml`
- Managed node groups with `privateNetworking: true` — nodes always in private subnets
- EBS CSI driver installed as an EKS addon (via ClusterConfig) with IRSA
- StorageClass provisioner is `ebs.csi.aws.com`
- eksctl auto-tags subnets for NLB provisioning (`kubernetes.io/role/elb=1` on public, `kubernetes.io/role/internal-elb=1` on private)

### K8ssandra Operator
- Must be installed to `--namespace default` — the Helm chart deploys workloads to the release namespace, and webhook configs must match
- K8ssandraCluster CR name is `demo`, which generates the `demo-superuser` secret
- Cassandra version: 5.0.8

### Networking
- easy-cass-mcp requires `FASTMCP_SERVER_HOST=0.0.0.0` to accept NLB traffic (FastMCP defaults to 127.0.0.1)
- The `service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing` annotation is required for external NLB access
- Cassandra Python driver discovers pod IPs and tries direct connections — keep MCP server in-cluster, not local

### Claude Desktop Integration
- Use `npx mcp-remote http://<NLB>:8000/mcp/ --allow-http` as stdio bridge
- Non-HTTPS endpoints require `--allow-http` flag
- `npx`/`kubectl`/`aws` may need symlinking to `/usr/local/bin` for Claude Desktop's PATH
- Each redeploy provisions a fresh NLB with a new hostname. `scripts/deploy.sh` rewrites the project `.mcp.json` automatically (used by Claude Code), but `~/Library/Application Support/Claude/claude_desktop_config.json` is **not** auto-updated — the user must update the `easy-cass-mcp` URL there after every redeploy.

### NoSQLBench
- Docker image binary is at `/nb5.jar`, invoke via `java -jar /nb5.jar`
- Built-in workloads not bundled in image — use ConfigMap-mounted custom workloads
- Template `<<var>>` syntax not supported — hardcode values in workload YAML

## Deployment Parameters

Scripts accept configuration via environment variables:
- `CLUSTER_NAME` — EKS cluster name (default: `k8ssandra-cluster`)
- `REGION` — AWS region (default: `us-east-1`)

## Common Pitfalls

1. NLB fails to provision → cluster not created with provided ClusterConfig (subnets not tagged)
2. Webhook errors on K8ssandraCluster creation → operator installed in wrong namespace
3. K8ssandraCluster patch rejected with "storageConfig must be defined" → strategic-merge replaced the datacenter array; use JSON patch targeting `/spec/cassandra/datacenters/0/size` instead
4. easy-cass-mcp unreachable via NLB → FastMCP binding to localhost instead of 0.0.0.0
5. NoSQLBench `nb5: not found` → use `java -jar /nb5.jar`, not `nb5` directly
6. NoSQLBench can't reach target rate above ~60k ops/sec → `threads=auto` picks too few; set `threads=400` (or higher) explicitly
7. One Cassandra pod shows 3-4× higher read latency than peers → NB pod is co-located on the same EC2 node; soft anti-affinity in the job spec plus Cassandra resource requests address this

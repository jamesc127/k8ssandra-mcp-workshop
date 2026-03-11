# K8ssandra on EKS Workshop

## Project Overview

Workshop repo for teaching Apache Cassandra on Amazon EKS using k8ssandra-operator, with MCP-based AI tooling (easy-cass-mcp) for cluster management via Claude Desktop.

## Architecture

- **EKS** cluster with managed node groups (3x `m5.xlarge` in private subnets)
- **3-node Cassandra ring** (datacenter: `dc1`) managed by k8ssandra-operator
- **k8ssandra-operator** installed to `default` namespace (required for webhook alignment)
- **easy-cass-mcp** deployed in-cluster, exposed via internet-facing NLB on port 8000
- **cert-manager** handles TLS for operator webhooks
- **NoSQLBench** provides on-demand CQL load testing

## Key Files

```
manifests/
  infra/eksctl-cluster.yaml             # EKS ClusterConfig (node groups, EBS CSI addon, OIDC)
  infra/storageclass.yaml               # EBS gp3 (ebs.csi.aws.com)
  cassandra/k8ssandra-cluster.yaml      # K8ssandraCluster CR (3 nodes, 512M heap, 5Gi storage)
  apps/easy-cass-mcp-*.yaml             # MCP server deployment + NLB service
  loadtest/nosqlbench-*.yaml            # CQL key-value workload + Job
scripts/
  deploy.sh                            # Full 5-step orchestrated deployment
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
- Cassandra version: 4.0.1

### Networking
- easy-cass-mcp requires `FASTMCP_SERVER_HOST=0.0.0.0` to accept NLB traffic (FastMCP defaults to 127.0.0.1)
- The `service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing` annotation is required for external NLB access
- Cassandra Python driver discovers pod IPs and tries direct connections — keep MCP server in-cluster, not local

### Claude Desktop Integration
- Use `npx mcp-remote http://<NLB>:8000/mcp/ --allow-http` as stdio bridge
- Non-HTTPS endpoints require `--allow-http` flag
- `npx`/`kubectl`/`aws` may need symlinking to `/usr/local/bin` for Claude Desktop's PATH

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
3. easy-cass-mcp unreachable via NLB → FastMCP binding to localhost instead of 0.0.0.0
4. NoSQLBench `nb5: not found` → use `java -jar /nb5.jar`, not `nb5` directly

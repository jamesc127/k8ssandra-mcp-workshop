# K8ssandra on EKS Workshop

## Project Overview

Workshop repo for teaching Apache Cassandra on Amazon EKS using k8ssandra-operator, with MCP-based AI tooling (easy-cass-mcp) for cluster management via Claude Desktop.

## Architecture

- **EKS** cluster, pre-provisioned out-of-band, in one of two profiles:
  - *trial* (`eksctl-cluster.yaml`) — 5 workers: 3 Cassandra (one per AZ), 1 tainted `loadgen`, 1 `utility`
  - *full* (`eksctl-cluster-full.yaml`) — 10 workers: 9 Cassandra (3 per AZ), 1 tainted `loadgen`
- **Cassandra ring** (datacenter: `dc1`) with **rack-per-AZ placement** (rack1/rack2/rack3) under cass-operator's default hard pod anti-affinity — one pod per node
- **Reaper** (repairs), **Medusa** (S3 backups via IRSA), and **kube-prometheus-stack** (Prometheus + Grafana) deployed alongside
- **k8ssandra-operator** installed to `default` namespace (required for webhook alignment)
- **easy-cass-mcp** deployed in-cluster, exposed via internet-facing NLB on port 8000
- **cert-manager** handles TLS for operator webhooks
- **metrics-server** installed in `kube-system` for `kubectl top` node/pod metrics
- **NoSQLBench** provides CQL load testing in two stages: a prepare job (schema + bulk load) and a sustained load job, both pinned to the tainted `loadgen` node

## Key Files

```
manifests/
  infra/eksctl-cluster.yaml             # TRIAL ClusterConfig — 5 workers, 3 AZs (default)
  infra/eksctl-cluster-full.yaml        # FULL ClusterConfig — 10 workers, 3 AZs
  infra/storageclass.yaml               # EBS gp3, 6000 IOPS / 500 MB/s
  infra/medusa-irsa.md                  # S3 bucket + IAM + IRSA setup (run out-of-band)
  cassandra/k8ssandra-cluster.yaml      # TRIAL CR — size 3, racks, 8G heap, 60Gi, no CPU limit
  cassandra/k8ssandra-cluster-full.yaml # FULL CR — size 6, scales to 9
  cassandra/medusa-backup-job.yaml      # On-demand MedusaBackupJob (full)
  monitoring/values-*.yaml              # kube-prometheus-stack Helm values
  apps/easy-cass-mcp-*.yaml             # MCP server deployment + NLB service
  loadtest/nosqlbench-configmap.yaml    # CQL key-value workload (dataset size hardcoded)
  loadtest/nosqlbench-prepare-job.yaml  # Schema + bulk load — run once, ahead of time
  loadtest/nosqlbench-job.yaml          # Sustained read/write load
scripts/
  deploy.sh                            # Full 9-step orchestrated deployment (charts pinned)
  teardown.sh                          # Reverse-order resource cleanup
docs/
  TROUBLESHOOTING.md                   # Known issues and fixes
  talk-outline.md                      # Talk structure and live-demo script
  architecture-diagrams.md             # ASCII topology, data flow, CRD relationships
  mcp-skills-cassandra-analysis.md     # Writeup of the 9-node / 100k ops-sec run
```

## Critical Conventions

### EKS Cluster
- Cluster is pre-provisioned out-of-band by the portal; `scripts/deploy.sh` never runs eksctl, and the cluster must NOT be deleted with `eksctl delete cluster`
- **3 AZs are mandatory** — the rack-per-AZ layout depends on it
- Managed node groups with `privateNetworking: true` — nodes always in private subnets
- Node groups carry `workload=cassandra|loadgen|utility` labels; the `loadgen` group is tainted `workload=loadgen:NoSchedule`
- EBS CSI driver installed as an EKS addon (via ClusterConfig) with IRSA
- StorageClass provisioner is `ebs.csi.aws.com`
- eksctl auto-tags subnets for NLB provisioning (`kubernetes.io/role/elb=1` on public, `kubernetes.io/role/internal-elb=1` on private)

### K8ssandra Operator
- Must be installed to `--namespace default` — the Helm chart deploys workloads to the release namespace, and webhook configs must match
- K8ssandraCluster CR name is `demo`, which generates the `demo-superuser` secret
- Cassandra version: 5.0.8; operator pinned to 1.33.0 (ships Reaper 5.0.1, Medusa 0.30.1, cass-operator 1.32.0)
- Ring `size` MUST be a multiple of 3 — rack-per-AZ placement goes unbalanced otherwise
- **Stargate is not deployed**: deprecated, and incompatible with Cassandra 5.0+

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
7. One Cassandra pod shows 3-4× higher read latency than peers → NB pod is co-located on the same EC2 node; the load generator now pins to a tainted `workload=loadgen` node instead of relying on soft anti-affinity, which silently no-ops once every node runs a Cassandra pod
8. Cassandra bootstrap stalls with `racks:` enabled → fewer than 3 AZs; `allocate_tokens_for_local_replication_factor=3` needs 3 racks. Pin `availabilityZones` in the ClusterConfig
9. No ServiceMonitor created and no error on the CR → kube-prometheus-stack was installed after the operator started; the operator's RESTMapper cache never saw the CRD. Install it first, or `kubectl rollout restart deployment/k8ssandra-operator`
10. Grafana panels all empty → published k8ssandra dashboards target the deprecated MCAC endpoint (`collectd_mcac_*`); Cassandra 5 emits `org_apache_cassandra_metrics_*` via the management API
11. Medusa uploads fail or hang → `secure` and `ssl_verify` render as `False` in the generated medusa.ini unless set explicitly in `spec.medusa.storageProperties`

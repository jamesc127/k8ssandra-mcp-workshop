# K8ssandra Workshop (OpenShift + EKS)

## Project Overview

Workshop repo for teaching Apache Cassandra on Kubernetes using k8ssandra-operator, with
MCP-based AI tooling (easy-cass-mcp) for cluster management via Claude Desktop.

**The live target is OpenShift on IBM Cloud** (IBM declined the EKS request). The EKS
manifests are kept and still work, but the OpenShift path is what gets rehearsed.

## Architecture

Three cluster profiles. **OpenShift is the live one** — IBM declined the EKS request, so the
workshop now targets an IBM TechZone OpenShift cluster. The EKS profiles are kept and still
work, but are not what is being rehearsed.

- **OpenShift** (`manifests/openshift/`) — **the active profile.** IBM TechZone, OpenShift
  4.19.38 / k8s 1.32.13, 5 workers x 32 vCPU / 125 GiB (3 masters tainted). Deploy with
  `scripts/deploy-openshift.sh`.
- **EKS trial** (`eksctl-cluster.yaml`) — 5 workers: 3 Cassandra (one per AZ), 1 tainted `loadgen`, 1 `utility`
- **EKS full** (`eksctl-cluster-full.yaml`) — 10 workers: 9 Cassandra (3 per AZ), 1 tainted `loadgen`
- **Cassandra ring** (datacenter: `dc1`) with three racks under cass-operator's default hard pod anti-affinity — one pod per node. On EKS racks map to AZs; **on OpenShift they map to nodes** via a synthetic `k8ssandra.io/rack` label, because that cluster has no `topology.kubernetes.io/zone` labels at all
- **Reaper** (repairs), **Medusa** (backups — AWS S3 via IRSA on EKS, in-cluster NooBaa via ObjectBucketClaim on OpenShift), and **kube-prometheus-stack** (Prometheus + Grafana) deployed alongside
- **k8ssandra-operator** installed to `default` namespace (required for webhook alignment)
- **easy-cass-mcp** deployed in-cluster. On EKS: internet-facing NLB on port 8000. **On OpenShift: a Route with edge TLS** — LoadBalancer services never provision on that cluster
- **cert-manager** handles TLS for operator webhooks
- **metrics-server** installed in `kube-system` for `kubectl top` — EKS only; OpenShift already serves `metrics.k8s.io`
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
  monitoring/values-*.yaml              # kube-prometheus-stack Helm values (EKS)
  openshift/node-labels.sh              # Label + taint the 5 OpenShift workers (racks live here)
  openshift/k8ssandra-cluster.yaml      # OPENSHIFT CR — size 3, node-racks, Ceph RBD, NooBaa S3
  openshift/medusa-obc.yaml             # ObjectBucketClaim — NooBaa bucket for Medusa
  openshift/easy-cass-mcp-service.yaml  # ClusterIP (no LoadBalancer on this cluster)
  openshift/routes.yaml                 # Routes: easy-cass-mcp, Reaper, Grafana
  openshift/values-*.yaml               # kube-prometheus-stack Helm values (OpenShift)
  apps/easy-cass-mcp-*.yaml             # MCP server deployment + NLB service
  loadtest/nosqlbench-configmap.yaml    # CQL key-value workload (dataset size hardcoded)
  loadtest/nosqlbench-prepare-job.yaml  # Schema + bulk load — run once, ahead of time
  loadtest/nosqlbench-job.yaml          # Sustained read/write load
scripts/
  deploy.sh                            # EKS: 9-step orchestrated deployment (charts pinned)
  teardown.sh                          # EKS: reverse-order resource cleanup
  deploy-openshift.sh                  # OPENSHIFT: 8-step deployment (charts pinned)
  teardown-openshift.sh                # OPENSHIFT: reverse-order resource cleanup
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
- Ring `size` MUST be a multiple of 3 — the three racks go unbalanced otherwise. On the 3-node OpenShift cluster that means size 3 is also the ceiling
- **Stargate is not deployed**: deprecated, and incompatible with Cassandra 5.0+

### OpenShift (the active platform)
- Cluster: IBM TechZone, OpenShift 4.19.38 / k8s 1.32.13. Credentials are gitignored:
  `conf_kubeconfig_itz-ckzpiv.conf`, `.env`, `vm_ssh_key_itz-ckzpiv.vm`. **Never commit these.**
- `export KUBECONFIG=$PWD/conf_kubeconfig_itz-ckzpiv.conf` to talk to it
- **No zone labels exist** — racks map to nodes via `k8ssandra.io/rack`, applied by
  `manifests/openshift/node-labels.sh`. Three racks is non-negotiable: the default
  `allocate_tokens_for_local_replication_factor=3` stalls bootstrap with fewer
- **LoadBalancer services never provision** (ODF's own `s3`/`sts` have been `<pending>` since
  the cluster was built) — use Routes
- Storage is **Ceph RBD via ODF** (`ocs-storagecluster-ceph-rbd`); there is no iops/throughput knob
- Medusa backs up to **NooBaa** (in-cluster S3) via an ObjectBucketClaim — no AWS, no IRSA.
  The OBC's secret is AWS_*-style; Medusa needs INI-format `credentials`, so deploy-openshift.sh translates it
- **metrics-server is not installed** — OpenShift already serves `metrics.k8s.io`
- kube-prometheus-stack **must** be installed with `--skip-crds`: the monitoring.coreos.com CRDs
  are owned by the cluster-version-operator. Our operator is scoped to `default` + `monitoring`
  so it does not fight OpenShift's. This holds only while user-workload monitoring stays disabled
- **The `default` namespace is load-bearing, not just convenient.** It carries
  `pod-security.kubernetes.io/enforce: privileged` — OpenShift exempts `default` from Pod
  Security Admission. Verified on this cluster: Cassandra pods run with `runAsUser: 999`
  (cass-operator's own value, NOT stripped, and NOT from the namespace's
  `1000000000/10000` UID range) and are admitted without an SCC grant. Moving the workshop
  to a dedicated project would subject it to PSA `restricted` and very likely break this —
  do not "tidy up" the namespace without re-testing
- Other namespaces are not exempt: Grafana and Prometheus run in `monitoring`, which is why
  every hardcoded `runAsUser` is nulled out in the OpenShift Helm values

### Networking
- easy-cass-mcp requires `FASTMCP_SERVER_HOST=0.0.0.0` to accept NLB traffic (FastMCP defaults to 127.0.0.1)
- The `service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing` annotation is required for external NLB access
- Cassandra Python driver discovers pod IPs and tries direct connections — keep MCP server in-cluster, not local

### Claude Desktop Integration
- Use `npx mcp-remote <url>` as stdio bridge
- EKS: `http://<NLB>:8000/mcp/` plus `--allow-http`, because the NLB is plain HTTP
- OpenShift: `https://<route-host>/mcp/` with **no** `--allow-http` — the Route terminates TLS at the edge
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
12. (OpenShift) Service stuck with no EXTERNAL-IP → this cluster has no cloud load-balancer integration; use a Route, not `type: LoadBalancer`
13. (OpenShift) `helm install kube-prometheus-stack` fails on existing CRDs → the monitoring.coreos.com CRDs belong to the cluster-version-operator; install with `--skip-crds`
14. (OpenShift) Pod rejected with "unable to validate against any security context constraint" → something pinned a `runAsUser` that `restricted-v2` will not admit; null it out so the namespace UID range applies, or grant `anyuid` to that ServiceAccount as a last resort
15. (OpenShift) Cassandra bootstrap stalls → check `k8ssandra.io/rack` labels; there must be 3 distinct values across `workload=cassandra` nodes
16. No CassandraDatacenter/pods/PVCs appear at all → a webhook rejected it; the reason is on the PARENT resource (`kubectl get k8ssandracluster demo -o jsonpath='{.status.error}'`), not on the CassandraDatacenter, which was never created
17. "multiple nodes per worker without cpu and memory requests and limits" → `softPodAntiAffinity: true` requires BOTH cpu and memory requests AND limits. It is mutually exclusive with omitting the CPU limit (the CFS-throttling fix). Set a limit high enough not to bind, or drop the co-location

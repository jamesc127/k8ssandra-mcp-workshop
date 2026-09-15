# K8ssandra on EKS Workshop

Deploy a production-style Apache Cassandra cluster on Amazon EKS using k8ssandra-operator, then manage it with AI tooling via Claude Desktop and MCP.

## Architecture

Two cluster profiles ship with this repo. The **trial** profile (5 workers) is the
default and is what `scripts/deploy.sh` targets; the **full** profile (10 workers)
is for the live workshop.

```
┌────────────────────────────────────────────────────────────────────────┐
│  EKS 1.34 — 3 AZs (required: rack-per-AZ needs 3 racks)                 │
│                                                                        │
│  workload=cassandra   us-east-1a      us-east-1b      us-east-1c       │
│  ┌──────────────────┐┌──────────────┐┌──────────────┐┌──────────────┐  │
│  │ rack1            ││ rack2        ││ rack3        ││              │  │
│  │ Cassandra 5.0.8  ││ Cassandra    ││ Cassandra    ││  1 pod/node  │  │
│  │ 8G heap, 60Gi    ││ + medusa     ││ + medusa     ││  hard anti-  │  │
│  │ no CPU limit     ││   sidecar    ││   sidecar    ││  affinity    │  │
│  └──────────────────┘└──────────────┘└──────────────┘└──────────────┘  │
│                                                                        │
│  workload=utility                     workload=loadgen (TAINTED)       │
│  ┌──────────────────────────────────┐ ┌──────────────────────────────┐ │
│  │ Prometheus + Grafana   Reaper    │ │ NoSQLBench                   │ │
│  │ k8ssandra-operator     easy-cass │ │ prepare job -> bulk load     │ │
│  │ cert-manager           -mcp      │ │ main job    -> sustained rw  │ │
│  └──────────────────────────────────┘ └──────────────────────────────┘ │
│                                                                        │
│  Medusa ──────────────────────────────────────────> S3 (via IRSA)      │
└──────────────┬─────────────────────────────────────────────────────────┘
               │ NLB (internet-facing, port 8000)
               ▼
┌──────────────────────┐
│  Claude Desktop      │  ← mcp-remote bridge → easy-cass-mcp
│  + Kubernetes MCP    │  ← API-based cluster management
└──────────────────────┘
```

| Profile | Workers | Cassandra nodes | Ring sizes | Load target |
|---|---|---|---|---|
| Trial (`eksctl-cluster.yaml`) | 5 x 32 vCPU/128 GB | 3 (1 per AZ) | 3 | ~60k ops/sec |
| Full (`eksctl-cluster-full.yaml`) | 9 x 16 vCPU + 1 x 32 vCPU | 9 (3 per AZ) | 3 / 6 / 9 | ~200k ops/sec |

Ring `size` must be a **multiple of 3** — rack-per-AZ placement goes unbalanced
otherwise, which is why the scale demo is 6 → 9 rather than 3 → 6 → 9.

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Apache Cassandra | 5.0.8 | Distributed database, rack-aware across 3 AZs |
| k8ssandra-operator | 1.33.0 | Cassandra lifecycle management |
| cass-operator | 1.32.0 | Bundled with the operator; owns the StatefulSets |
| Reaper | 5.0.1 | Anti-entropy repair orchestration |
| Medusa | 0.30.1 | Backup/restore to S3 |
| kube-prometheus-stack | 91.4.0 | Prometheus + Grafana |
| cert-manager | v1.21.2 | TLS certificates for operator webhooks |
| metrics-server | 3.14.0 | `kubectl top` node/pod CPU and memory |
| easy-cass-mcp | latest | MCP server for AI-powered Cassandra ops |
| NoSQLBench | 5.25.16 | CQL load testing |

**Stargate is deliberately not deployed.** It is deprecated and does not work with
Cassandra 5.0+; the operator emits a deprecation warning if you set the field.

## Prerequisites

- An EKS cluster **provisioned out-of-band** from one of the ClusterConfigs in
  `manifests/infra/` (see below) — this repo does not create it
- AWS CLI configured, with permission to create an S3 bucket and an IAM role
- `kubectl`, `eksctl` (for the IRSA service account only), Helm 3.x
- Node.js 18+ (for the `mcp-remote` bridge)
- Claude Desktop (for MCP integration)

## Quick Start

### 1. Provision the cluster

The ClusterConfigs are **submitted to the provisioning portal**, not applied with
`eksctl create cluster`. `scripts/deploy.sh` never runs eksctl and assumes the
cluster already exists.

- `manifests/infra/eksctl-cluster.yaml` — 5-node trial (default)
- `manifests/infra/eksctl-cluster-full.yaml` — 10-node full profile

Whichever you use, **three AZs are mandatory**. With fewer, Cassandra's default
`allocate_tokens_for_local_replication_factor=3` cannot allocate tokens and
bootstrap stalls — this is a failure this workshop actually hit. Verify first:

```bash
kubectl get nodes -L topology.kubernetes.io/zone,workload
```

You should see Cassandra nodes spread evenly across three zones, one node labelled
`workload=loadgen` (tainted), and on the trial profile one labelled
`workload=utility`. `deploy.sh` hard-stops if this is wrong.

> **Cost note:** the trial profile (5 × 32 vCPU / 128 GB) runs ≈ $9.7/hr in
> us-east-1; the full profile ≈ $9.1/hr. Release the reservation when you are not
> using it. Do **not** run `eksctl delete cluster` — the cluster is portal-managed.

### 2. Set up Medusa's S3 backend

Medusa needs a bucket and an IRSA role before anything is deployed. `deploy.sh`
deliberately creates no IAM resources; it only checks they exist and fails fast.

Follow [`manifests/infra/medusa-irsa.md`](manifests/infra/medusa-irsa.md), then
replace the bucket placeholder in the CR:

```bash
sed -i '' "s/REPLACE_WITH_MEDUSA_BUCKET/$BUCKET/" \
  manifests/cassandra/k8ssandra-cluster.yaml
```

### 3. Deploy everything

```bash
./scripts/deploy.sh
```

Nine steps, with every Helm chart version pinned — an unpinned chart that bumps
between a rehearsal and a live demo is the easiest way to break a working setup:

1. **Preflight** — AZ spread, node labels, Medusa IRSA, bucket placeholder
2. StorageClass (`ebs-gp3`, 6000 IOPS / 500 MB/s)
3. cert-manager
4. metrics-server
5. **kube-prometheus-stack** — must come *before* the operator (see below)
6. k8ssandra-operator
7. K8ssandraCluster, waiting on `CassandraDatacenter/dc1` becoming `Ready`
8. easy-cass-mcp + NoSQLBench ConfigMap
9. NLB, then `.mcp.json` is rewritten with the new hostname

> **Why the ordering matters:** the operator decides whether to emit
> ServiceMonitors by checking whether the ServiceMonitor CRD is registered,
> through a *cached* RESTMapper. Install kube-prometheus-stack after the operator
> pod has started and telemetry is skipped silently, with no error on the CR.
> `deploy.sh` restarts the operator to cover this.

Overridable via environment variables:

```bash
CASSANDRA_CR=manifests/cassandra/k8ssandra-cluster-full.yaml \
  GRAFANA_PASSWORD=hunter2 ./scripts/deploy.sh
```

### 4. Configure Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "cassandra": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "http://<NLB_HOSTNAME>:8000/mcp/",
        "--allow-http"
      ]
    },
    "kubernetes": {
      "command": "npx",
      "args": [
        "-y",
        "kubernetes-mcp-server@latest"
      ]
    }
  },
  "preferences": {
    "coworkScheduledTasksEnabled": true,
    "ccdScheduledTasksEnabled": true,
    "sidebarMode": "code",
    "coworkWebSearchEnabled": true
  }
}
```

Get the NLB hostname and substitute it into the config above:
```bash
kubectl get svc easy-cass-mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

> **Re-deploy note:** Every time you tear down and redeploy the workshop, a new NLB is provisioned with a different hostname. The project's `.mcp.json` (used by Claude Code) is rewritten automatically by `scripts/deploy.sh`, but `claude_desktop_config.json` (used by Claude Desktop) is **not** — you'll need to manually update the `easy-cass-mcp` URL there after each redeploy.

### 5. Run a load test

The workload is now **two stages**. Splitting them lets the main job run multiple
pods in parallel without each of them re-creating the schema and repeating the
bulk load.

```bash
# Stage 1 — schema + bulk load. Run once, well ahead of any demo.
kubectl apply -f manifests/loadtest/nosqlbench-prepare-job.yaml
kubectl logs -f job/nosqlbench-prepare

# Stage 2 — sustained 50/50 read/write
kubectl apply -f manifests/loadtest/nosqlbench-job.yaml
kubectl logs -f job/nosqlbench-load
```

The trial profile loads 20M rows (~11 GB per node at RF=3) and then drives ~60k
ops/sec for 3 hours. The old 500k-row dataset was ~45 MB — small enough to sit
entirely in page cache, which made Medusa backups finish instantly and Reaper
repairs meaningless.

Dataset size is **hardcoded in three places** (the `Mod()` and `Uniform()` bindings
in the ConfigMap, and `cycles=` in the prepare job) because the NoSQLBench image
does not support `<<template>>` syntax. Change them together.

Jobs are not re-runnable in place; delete first:

```bash
kubectl delete job nosqlbench-load && kubectl apply -f manifests/loadtest/nosqlbench-job.yaml
```

### 6. Operate the cluster

**Grafana**

```bash
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
# http://localhost:3000 — admin / workshop
```

> Published k8ssandra Grafana dashboards **will render empty**. For Cassandra
> newer than 4.0.3 the operator scrapes the management API (metric names
> `org_apache_cassandra_metrics_*`), while those dashboards target the deprecated
> MCAC endpoint (`collectd_mcac_*`). Build panels against the live names.

**Reaper**

```bash
kubectl port-forward -n default svc/demo-dc1-reaper-service 8080:8080
# http://localhost:8080/webui/index.html
```

The cluster registers itself. `autoScheduling` is off, so nothing repairs until
you start it.

**Medusa**

```bash
kubectl apply -f manifests/cassandra/medusa-backup-job.yaml
kubectl get medusabackupjob -n default -w
kubectl get medusabackup -n default
aws s3 ls "s3://$BUCKET/demo/" --recursive --human-readable --summarize
```

`backupType: full` re-uploads every sstable, so the backup takes visible time
rather than completing instantly off the back of a previous run.

**Scale the ring**

```bash
kubectl patch k8ssandracluster demo -n default --type=json \
  -p='[{"op":"replace","path":"/spec/cassandra/datacenters/0/size","value":6}]'
```

`size` must be a multiple of 3. A strategic-merge patch replaces the whole
`datacenters` array and the validating webhook rejects the result with
"storageConfig must be defined" — use a JSON patch.

On the trial profile the ring is capped at 3, because hard pod anti-affinity
allows one Cassandra pod per node and there are only 3 Cassandra nodes.

## Teardown

```bash
./scripts/teardown.sh
```

Removes all workshop resources in reverse order, including the Medusa backup
objects and the monitoring stack.

The EKS cluster itself is portal-managed — **do not** run `eksctl delete cluster`;
release the reservation instead. Medusa's S3 bucket and IAM role are also
out-of-band and are left intact; see
[`manifests/infra/medusa-irsa.md`](manifests/infra/medusa-irsa.md) to remove them.

## Workshop Findings

Three real-world scenarios validated during a sustained 100k TPS run on the
**previous** 6-node, single-rack topology. The measurements stand as a record of
what was observed; where the repo has since changed in response, that is called
out inline.

### 1. Noisy-neighbor latency (and how the defaults defend against it)

**Symptom:** During an initial run, one Cassandra pod showed **~4× higher read latency** than its peers (172 µs vs ~42 µs). Writes were nearly unaffected.

**Diagnosis:** The NoSQLBench pod and that Cassandra pod were scheduled onto the same EC2 instance. Both were `BestEffort` QoS, so neither had guaranteed CPU shares. The shared L3 cache and scheduling jitter degraded the read path disproportionately — writes are CPU-cheap (CommitLog + memtable), but reads exercise key cache, bloom filter, memtable/SSTable scan, and deserialization, which are all CPU- and cache-sensitive.

**Mitigations applied at the time:**
- Cassandra pods declared `resources.requests: cpu=4, memory=3Gi` → `Burstable` QoS, equal cpu.shares vs NoSQLBench (also requesting `cpu=4`).
- The NoSQLBench Job used *soft* (`preferredDuringSchedulingIgnoredDuringExecution`) pod anti-affinity against `app.kubernetes.io/name=cassandra`. Soft rather than required, because a fully-scaled cluster (6 EKS nodes / 6 Cassandra pods) left no Cassandra-free node.
- `cassandraYaml.dynamic_snitch_badness_threshold: 0.1` (down from the 1.0 default). At sub-millisecond latencies, the default lets the dynamic snitch ignore everything short of a 100%-worse replica, which lets a co-located hot replica become self-reinforcing. 0.1 is the documented modern recommendation and lets the snitch route reads away from a degraded replica much sooner.

> **What changed since:** soft anti-affinity was the weak link — it silently
> degrades to a no-op once every node runs a Cassandra pod, which is exactly the
> case that produced this finding. The load generator now runs on a dedicated node
> tainted `workload=loadgen:NoSchedule`, so co-location cannot happen at all. The
> dynamic snitch setting is retained.

**Measured outcome under the worst case (forced co-location after scaling to 6 Cassandra pods on 6 EKS nodes):**

| Pod | Co-located with NB? | Read latency (avg) |
|---|---|---|
| Isolated pods | no | 44–66 µs |
| Co-located pod (was 172 µs before fix) | yes | **79 µs** |

Co-location penalty dropped from **~4×** to **~1.3×** — a ~85% reduction. When the scheduler can find a Cassandra-free node, the penalty is zero.

### 2. Elastic scale-up under load

We patched `K8ssandraCluster.spec.cassandra.datacenters[0].size` from 3 to 6 mid-test:

```bash
kubectl patch k8ssandracluster demo -n default --type=json \
  -p '[{"op":"replace","path":"/spec/cassandra/datacenters/0/size","value":6}]'
```

(Strategic-merge patches are rejected by the operator's validating webhook because they overwrite the datacenters array and drop required fields like `storageConfig`. Use JSON patch to target the specific field.)

> **What changed since:** with rack-per-AZ placement, `size` must be a multiple of
> 3, so the equivalent demo is now 6 → 9.

Throughout the ~8 minute scale-up:
- 100k ops/sec rate held to within 1% (samples spanned 99,499 – 100,574 ops/sec)
- Three new pods (sts-3, sts-4, sts-5) bootstrapped streaming data from the originals
- Per-pod CPU on the originals dropped 17–22% as new pods came online — work rebalancing in real time
- `nodetool status` showed ownership transition: 60% per pod (5 nodes mid-join) → 50% per pod (6 nodes settled). Perfect for RF=3.
- Zero dropped queries, zero `LOCAL_QUORUM` violations

### 3. Pod-failure resilience

We force-killed a long-running Cassandra pod (`--grace-period=0 --force`) mid-test to simulate a node crash with no graceful drain. Observed:
- **Rate held at 100k throughout** — `RF=3 + LOCAL_QUORUM` means 2 healthy replicas always satisfy quorum.
- A few transient driver warnings (`ConnectionInitException` while the cqld4 driver refreshed topology) but **zero failed queries**.
- The StatefulSet controller recreated the pod, which mounted the same PVC (same Host ID) and rejoined the ring in ~45s.
- No bootstrap streaming needed — because the data was already on disk, Cassandra saw "the same node coming back from a brief outage."
- The 5 surviving pods absorbed the lost pod's share with a ~1 core CPU bump each.

This is the standard `RF=3 + LOCAL_QUORUM + StatefulSet + PVC` resilience story — but it's worth seeing it work in practice.

## Directory Structure

```
k8ssandra-workshop/
├── CLAUDE.md                                  # AI assistant context
├── README.md
├── manifests/
│   ├── infra/
│   │   ├── eksctl-cluster.yaml                # TRIAL ClusterConfig — 5 workers, 3 AZs
│   │   ├── eksctl-cluster-full.yaml           # FULL ClusterConfig — 10 workers, 3 AZs
│   │   ├── storageclass.yaml                  # EBS gp3, 6000 IOPS / 500 MB/s
│   │   └── medusa-irsa.md                     # S3 bucket + IAM + IRSA runbook
│   ├── cassandra/
│   │   ├── k8ssandra-cluster.yaml             # TRIAL CR — size 3, racks, Reaper, Medusa
│   │   ├── k8ssandra-cluster-full.yaml        # FULL CR — size 6, scales to 9
│   │   ├── medusa-backup-job.yaml             # On-demand MedusaBackupJob (full)
│   │   └── cassandra-no-operator.yaml         # Raw StatefulSet fallback (unused)
│   ├── monitoring/
│   │   └── values-kube-prometheus-stack.yaml  # Prometheus + Grafana Helm values
│   ├── apps/
│   │   ├── easy-cass-mcp-deployment.yaml      # MCP server deployment
│   │   └── easy-cass-mcp-service.yaml         # Internet-facing NLB service
│   └── loadtest/
│       ├── nosqlbench-configmap.yaml          # CQL key-value workload
│       ├── nosqlbench-prepare-job.yaml        # Schema + bulk load (run once)
│       └── nosqlbench-job.yaml                # Sustained read/write load
├── docs/
│   ├── TROUBLESHOOTING.md                     # Known issues and fixes
│   ├── talk-outline.md                        # Talk structure and demo script
│   ├── architecture-diagrams.md               # Topology, data flow, CRD relationships
│   └── mcp-skills-cassandra-analysis.md       # Writeup of the 9-node / 100k run
└── scripts/
    ├── deploy.sh                              # 9-step deployment orchestration
    └── teardown.sh                            # Resource cleanup
```

## Key Gotchas

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Cassandra bootstrap stalls with racks enabled | Fewer than 3 AZs; `allocate_tokens_for_local_replication_factor=3` needs 3 racks | Pin `availabilityZones` in the ClusterConfig; `deploy.sh` preflights this |
| No ServiceMonitor, and no error on the CR | kube-prometheus-stack installed after the operator started; its RESTMapper cache never saw the CRD | Install it first, or `kubectl rollout restart deployment/k8ssandra-operator` |
| Grafana panels all empty | Community dashboards target the deprecated MCAC endpoint | Build panels against `org_apache_cassandra_metrics_*` |
| Medusa uploads fail or hang | `secure`/`ssl_verify` render as `False` in the generated medusa.ini | Set both explicitly in `spec.medusa.storageProperties` |
| Medusa sidecar has no AWS credentials | Pod not running under the IRSA service account | Set `spec.cassandra.serviceAccount: medusa-backup` |
| `size` patch rejected — "storageConfig must be defined" | Strategic-merge replaced the datacenters array | Use a JSON patch on `/spec/cassandra/datacenters/0/size` |
| NoSQLBench pods stay Pending | No node labelled `workload=loadgen`, or the toleration is missing | Check node labels and the taint |
| NLB won't provision | Subnets missing load balancer tags | Ensure the cluster was created from the provided ClusterConfig |
| Webhook errors on K8ssandraCluster | Operator in wrong namespace | Install k8ssandra-operator to `default` |
| easy-cass-mcp unreachable via NLB | FastMCP binds to 127.0.0.1 by default | Set `FASTMCP_SERVER_HOST=0.0.0.0` (already configured) |
| easy-cass-mcp logs "Bad credentials" | Started before the superuser secret was usable | `kubectl rollout restart deployment/easy-cass-mcp` (deploy.sh does this) |
| Claude Desktop "No such file" | `npx`/`kubectl` not in Claude's PATH | Symlink to `/usr/local/bin` |
| NoSQLBench `nb5: not found` | Docker entrypoint override | Use `java -jar /nb5.jar` (already configured) |

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the full troubleshooting guide.

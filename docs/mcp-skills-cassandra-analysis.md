# Administering Cassandra with MCP + Skills: A Live Workshop Walkthrough

> **What this is**: A real session showing how MCP-based tooling and Claude Code skills (`/diagnose`, `/optimize`, `/expert`) work together to operate, observe, and tune a live Apache Cassandra 5.0.8 cluster. Every metric, finding, and recommendation in this document came out of one continuous Claude Code session driving a 9-node ring on EKS through a 1-hour 100k ops/sec load test.

---

## TL;DR

We deployed a 3-node K8ssandra cluster on EKS, scaled it live to 6 then to 9 nodes during a sustained 100k ops/sec NoSQLBench workload, and used MCP tools (`easy-cass-mcp`) plus three specialized Cassandra skills to gather metrics, diagnose performance, recommend optimizations, and produce an expert-grade post-mortem — all from a single Claude Code session, with no manual JMX, no jolokia, no Prometheus exporter, no Grafana dashboard.

The cluster sustained **~92k ops/sec** of the 100k target with **zero errors, zero blocked tasks, and zero bloom filter false positives**. We then identified exactly where the 8k-ops/sec shortfall came from (Kubernetes CPU-limit CFS throttling), and produced concrete tier-ranked tuning to push past it.

---

## The cluster under test

| Aspect | Value |
|---|---|
| Cassandra version | 5.0.8 |
| Orchestration | k8ssandra-operator on Amazon EKS |
| EC2 footprint | 6 × m5.4xlarge (16 vCPU / 64 GiB) |
| Cassandra topology | 1 DC (`dc1`), RF=3, scaled 3 → 6 → 9 pods during the run |
| Per-pod resources | requests 4 CPU / 3 GiB, limits 6 CPU / 6 GiB, heap 2 GiB |
| Affinity | `softPodAntiAffinity: true` (allows 2+ Cassandra pods per EC2 node above 6 pods) |
| Workload | NoSQLBench `cql-keyvalue`, 50/50 read/write, CL=LOCAL_QUORUM, `threads=400`, `errors=count` |
| Target rate | 100,000 ops/sec for 1 hour (360M cycles) |

---

## What we observed

### Run summary

| Metric | Value |
|---|---|
| Total cycles completed | 360,000,000 (100%) |
| Wall clock | 65 min 16 sec |
| Sustained throughput | ~92,000 ops/sec average |
| Errors (NB) | 0 |
| Exceptions (Cassandra log) | 0 |
| Bloom filter false positives | 0 (all 9 nodes) |
| Blocked thread pool tasks (lifetime) | 0 across every pool, every node |
| Pending thread pool tasks at any sample | 0 |
| Bootstrap streaming per new node | 42-138 MB in 6.7-9.8 seconds |

### Per-replica latency (lifetime mean, from `nodetool tablestats`)

| Pod | Generation | Local reads | Mean read | Local writes | Mean write | SSTables |
|---|---|---|---|---|---|---|
| sts-0 | original 3 | 75.3M | 45.6 µs | 119.8M | 69.0 µs | 2 |
| sts-5 | added 3→6 | 30.0M | 34.5 µs | 40.4M | 22.2 µs | 1 |
| sts-8 | added 6→9 | 17.3M | 72.2 µs | 27.2M | 43.2 µs | 3 |

### Replication math (from `system_views.local_*_latency.count`)

- **~361M local reads / 180M client reads = 2.0 ratio → CL=LOCAL_QUORUM confirmed**
- **~547M local writes / 180M client writes = 3.0 ratio → RF=3 confirmed**

### EC2-host CPU at 9-node scale

| Node | Pods on it | CPU % |
|---|---|---|
| ip-10-0-14-156 | sts-0, sts-6 | 70% |
| ip-10-0-29-78 | sts-2, sts-4 | 68% |
| ip-10-0-31-226 | sts-3, sts-7 | 64% |
| ip-10-0-4-222 | sts-1, sts-8 | 63% |
| ip-10-0-8-117 | sts-5 only | 33% |
| ip-10-0-17-45 | NoSQLBench only | 43% |

Every Cassandra pod sat at **5.6-5.99 cores / 6.0 cores limit** throughout the test.

---

## How the MCP tooling enabled this

The cluster's `easy-cass-mcp` server, exposed through an internet-facing AWS NLB, gave Claude Code first-class CQL-and-system-tables access without any of the usual JMX/jolokia/exporter scaffolding. The tools that did the work:

| MCP tool | What it did |
|---|---|
| `query_all_nodes(cql)` | Fanned out a CQL query to every replica and labeled results by node — essential for the `system_views.*` virtual tables which are per-node |
| `query_node(addr, cql)` | Targeted a single replica for schema introspection or single-node deep dives |
| `query_system_table(keyspace, table)` | Curated access to the system keyspaces (peers, local, sstable_activity, etc.) |
| `get_create_table(keyspace, table)` | Pulled the canonical schema for a table — fed directly into the data-model and optimization analyses |
| `analyze_table_optimizations(keyspace, table)` | Returned compaction-strategy recommendations specific to the running version |

Combined with `kubectl` for pod/host stats and `nodetool` via `kubectl exec` for the durable lifetime counters that virtual tables decay out of, the MCP surface covered all of the observation we needed.

### What this replaced

In a traditional ops setup, the same investigation would have needed:

- JMX exporter sidecar per pod
- Prometheus scraping all 9 pods
- Grafana dashboards configured for each metric
- Or: SSH/kubectl-exec to each pod individually and `nodetool tpstats / tablestats / proxyhistograms` on each

**Time-to-first-insight with that stack: half a day, minimum.**

With MCP + Claude Code's `query_all_nodes`: **seconds**, and the data lands as structured tables already labeled by node — directly usable.

---

## Skills as force multipliers

Three specialized Cassandra skills ran on top of the MCP-collected data, each with a different lens. The pattern: gather raw observations with MCP, then hand them to a skill for opinionated analysis.

### `/diagnose` — systematic problem-finding

Applied the USE method (Utilization / Saturation / Errors) across CPU, memory, disk I/O, network, and thread pools, comparing all 9 nodes for outliers. Confirmed three things and flagged one:

| Concern | Verdict |
|---|---|
| Read-count skew (sts-1: 99.7M vs sts-8: 14.4M) | **Not a problem** — historical accumulation across the 3→6→9 scale events, not current imbalance |
| Speculative retries (158k on sts-0) | **Normal** — 0.19% of requests, well below the 1% expected from `speculative_retry='99p'` |
| CPU pods at limit, hosts at 30-70% | **Real finding** — CFS throttling at the cgroup level is invisible to `tpstats.pending_tasks`; this caused the 92k vs 100k shortfall |
| UCS keeping 2-3 SSTables per pod | **Healthy** — UCS T4 working as designed; small dataset doesn't warrant deeper compaction |

The CPU-throttling diagnosis is the kind of insight that requires connecting two observations a flat dashboard would never join: "pods pegged at limit" *and* "hosts have headroom" *and* "no thread-pool queue depth." The skill applied the USE framework rigorously to reach it.

### `/optimize` — concrete tunable recommendations

Tier-ranked the changes, with concrete `ALTER TABLE` and `cassandra.yaml` deltas. Highlights:

**Tier 1 (highest impact for this workload):**

1. Re-enable key cache. The operator default ships `key_cache_size_in_mb: 0`, but the table requests `caching: {keys: ALL}`. The table-level setting is meaningless without the YAML setting. Fix: `key_cache_size_in_mb: 100`.
2. Raise the CPU limit to 12 (or remove it entirely). 6 cores caused the throttling that capped throughput.
3. Drop compression chunk size from 16 KiB to 4 KiB. Current setting decompresses 16 KiB per point lookup of a small value — 250× I/O amplification.

**Tier 2 (C* 5 best practices the operator defaults missed):**

4. `num_tokens` from 16 → 4. The operator default is the Cassandra default. **Both are wrong**; production should use 1 or 4. With RF=3, neighbor count drops from 64 to 16, streaming gets faster, blast radius shrinks.
5. Enable Trie memtables (C* 5 feature, off by default).
6. `commitlog_sync_period_in_ms: 1000` (default 10000 — 10s window of data loss is outdated on modern hardware).
7. **Lower** `compaction_throughput_mb_per_sec` to 16 (per CASSANDRA-19987 — high throughput pollutes page cache and harms read latency).

**Tier 3 (direct answers to specific questions):**

- `concurrent_reads: 32` is fine for 6-core pods (rule of thumb is 4×cores; observed `pending_tasks: 0` confirms).
- Memtable budget (480 heap + 480 offheap) is well-sized for the 2 GiB heap; keep it.

Expected total impact if all Tier 1+2 changes are applied: **~110-120k ops/sec on the same hardware** vs. the current 92k.

### `/expert` — the opinionated big-picture take

Where `/diagnose` finds problems and `/optimize` fixes them, `/expert` answers questions like:

- **"Did the workshop model any operational anti-patterns?"** Yes: `num_tokens: 16`, CPU limits on JVM workloads, 2GiB heap, NB co-located in cluster — all defensible for a demo, all dangerous if attendees take them as recommendations.
- **"Is `softPodAntiAffinity: true` ever defensible in production?"** Rarely. The trade-off:

  | Aspect | One pod per node | Multiple pods per node |
  |---|---|---|
  | EC2 failure blast radius | 1 replica | 2+ replicas |
  | RF=3 + QUORUM safety | Survives 1 host loss | Can drop below QUORUM on single host loss |
  | Page cache | Each Cassandra gets the host | Two JVMs fight for it |
  | EBS IOPS | Whole budget per pod | Shared per attachment |

  Defensible only for dev / CI / workshop / single-host edge sites. Not for any RF=3 prod cluster where availability matters.

- **"What 'just works' moment is workshop-worthy?"** `kubectl patch ... size: 3 → 9` with no errors, no manual intervention, while serving 92k ops/sec. Bootstrap streams complete in seconds via Zero-Copy. In 2018 this was a multi-day project; in 2026 it's a kubectl one-liner.

- **"What about `system_views` gotchas?"** Several important ones — see [Virtual-table gotchas](#virtual-table-gotchas-cassandra-5) below.

---

## Virtual-table gotchas (Cassandra 5)

The `system_views.*` virtual tables are a transformative observability surface, but they have sharp edges that bit us during this session:

1. **Latency percentile columns use a decaying reservoir** (~5-15 minute half-life). Stop the workload and `p50/p99/max` decay to 0 quickly. They are *live observation*, not SLI history. Use Prometheus + Cassandra Exporter for historical SLIs.
2. **The `count` columns ARE monotonic and lifetime-cumulative.** This is the durable signal — they survive load stop and give the true work-done history.
3. **`per_second` is EWMA, not "now."** Decays to ~0 a few minutes after load stops.
4. **Observer effect is real.** Every `SELECT FROM system_views.coordinator_read_latency` bumps `coordinator_scan_latency`. Query less frequently than you'd think for tight measurement windows.
5. **They're per-node tables.** Bare `SELECT FROM system_views.foo` returns local data only. Need `query_all_nodes` (MCP) or per-node fan-out (cqlsh against each node).
6. **Column naming is inconsistent across tables**: `mebibytes` vs `bytes`, `p50th_ms` vs `p50th`, `max_ms` vs `max`. Always `DESC` first.
7. **`coordinator_*_latency` is server-side only.** No client→coordinator network RTT. `local_*_latency` is replica-side only. Neither matches what the driver measures end-to-end.
8. **`tombstones_per_read.count` = read count** when there are no tombstones — the name suggests "tombstones encountered" but it's actually "reads that encountered any tombstones, including zero." Easy to misread.

---

## The workshop's headline "just works" moment

If you take one thing from this session: **scaling Apache Cassandra under load is no longer an event**.

```
kubectl patch k8ssandracluster demo --type=json \
  -p='[{"op":"replace","path":"/spec/cassandra/datacenters/0/size","value":9}]'
```

Six minutes later, 9 nodes are in the ring. While that happened:

- The 3 → 6 transition added 3 nodes in ~5.5 minutes, one bootstrap at a time.
- The 6 → 9 transition added 3 more in ~5.4 minutes.
- Each new node streamed 42-138 MB of data in 6.7-9.8 seconds via Zero-Copy Streaming.
- Existing nodes kept serving NoSQLBench's 100k ops/sec target with zero NB errors.
- The driver's token-aware policy picked up the new coordinators within seconds of gossip propagation.
- RF=3 was maintained continuously.

Achieved throughput climbed from ~32k (3 nodes) to ~85k (6 nodes) to ~105k (9 nodes, after the driver pool warmed). The shape was roughly linear in node count, exactly as it should be.

The combination of operator-managed orchestration, Zero-Copy Streaming, and the MCP observation surface meant we could **operate, observe, and reason about** this scale event in real time, from a single chat session — no dashboards to context-switch to, no `kubectl exec` loops to write, no JMX hand-rolling.

---

## What the operator defaults missed

A non-trivial finding: **the k8ssandra-operator's default `cassandra.yaml` is not a production-tuned starting point**. Specifically, it ships:

- `key_cache_size_in_mb: 0` (disabled, contradicting the table's `caching: ALL` setting)
- `num_tokens: 16` (the C* default; production should use 4)
- `commitlog_sync_period_in_ms: 10000` (10s of write loss window on pod death)
- Stock `compaction_throughput_mb_per_sec: 64` (high enough to harm read latency per CASSANDRA-19987)
- Trie memtables not enabled (a free C* 5 win)

None of these are operator bugs — they're conservative defaults inherited from Cassandra itself. But they're the difference between "Cassandra running on Kubernetes" and "Cassandra running *well* on Kubernetes." The MCP + skills loop surfaced all of them in under an hour.

---

## What this enables

For anyone running Cassandra on Kubernetes today, this workflow demonstrates:

1. **First-class observability without a metrics pipeline.** MCP-exposed `query_all_nodes` against `system_views` is sufficient for ad-hoc investigation and live demos. (Add Prometheus on top for SLI history.)
2. **AI-assisted ops with grounding.** The skills (`/diagnose`, `/optimize`, `/expert`) bring real Cassandra expert practice into the loop — they're not generic "ask an LLM" wrappers. They apply USE-method diagnostics, Jon Haddad's published `num_tokens` and compaction stances, and version-specific C* 5 features (UCS, Trie memtables, BTI, Zero-Copy Streaming).
3. **A short loop from observation to recommendation to remediation.** Gather data with MCP → analyze with skills → apply with `kubectl patch` or `ALTER TABLE` → re-measure with MCP. All in one chat context.
4. **Lower cognitive overhead for cluster operators.** No more tab-switching between Grafana, kubectl, cqlsh, and JIRA. The agent drives all of them and synthesizes.

For workshop attendees specifically: the live scaling demo is the technical hook, but the **observability-and-analysis loop is the durable takeaway**. The pattern of "let the MCP tool gather, let the skill reason, let the operator decide" generalizes to any Cassandra fleet — workshop, staging, or production.

---

## Appendix: full settings inventory captured during the session

For reproducibility, the following YAML settings were observed via `system_views.settings` on a 5.0.8 pod:

```
authenticator: PasswordAuthenticator
authorizer: CassandraAuthorizer
auto_snapshot: true
commitlog_sync: periodic
commitlog_total_space_in_mb: 1238
compaction_throughput_mb_per_sec: 64
concurrent_reads: 32
concurrent_writes: 32
disk_optimization_strategy: ssd
file_cache_size_in_mb: 480
incremental_backups: false
inter_dc_stream_throughput_outbound_megabits_per_sec: 201
key_cache_size: 0MiB
key_cache_size_in_mb: 0
memtable_allocation_type: offheap_objects
memtable_cleanup_threshold: 0.33333334
memtable_flush_writers: 2
memtable_heap_space_in_mb: 480
memtable_offheap_space_in_mb: 480
native_transport_max_concurrent_requests_in_bytes: 201326592
native_transport_max_threads: 128
num_tokens: 16
read_request_timeout_in_ms: 5000
request_timeout_in_ms: 10000
row_cache_size_in_mb: 0
snapshot_before_compaction: false
sstable_preemptive_open_interval_in_mb: 50
stream_throughput_outbound_megabits_per_sec: 201
write_request_timeout_in_ms: 2000
```

Schema for the load-test table:

```sql
CREATE TABLE baselines.keyvalue (
    key text PRIMARY KEY,
    value text
) WITH additional_write_policy = '99p'
    AND bloom_filter_fp_chance = 0.01
    AND caching = {'keys': 'ALL', 'rows_per_partition': 'NONE'}
    AND compaction = {
        'class': 'org.apache.cassandra.db.compaction.UnifiedCompactionStrategy',
        'max_sstables_to_compact': '64',
        'min_sstable_size': '100MiB',
        'scaling_parameters': 'T4',
        'sstable_growth': '0.3333333333333333',
        'target_sstable_size': '1GiB'
    }
    AND compression = {'chunk_length_in_kb': '16', 'class': 'org.apache.cassandra.io.compress.LZ4Compressor'}
    AND crc_check_chance = 1.0
    AND default_time_to_live = 0
    AND gc_grace_seconds = 864000
    AND max_index_interval = 2048
    AND memtable_flush_period_in_ms = 0
    AND min_index_interval = 128
    AND read_repair = 'BLOCKING'
    AND speculative_retry = '99p';
```

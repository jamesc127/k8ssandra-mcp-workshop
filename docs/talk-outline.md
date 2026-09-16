# Control C* Con Claude Code: k8ssandra, MCP, and Skills

**Event:** [Planet Cassandra #18](https://luma.com/1osqeg4d) — Zoom webcast
**Format:** 60-minute talk + live demo, ~10 min Q&A
**Repo:** k8ssandra-workshop
**Companion repos:**
- MCP server: [rustyrazorblade/easy-cass-mcp](https://github.com/rustyrazorblade/easy-cass-mcp)
- Skills: [rustyrazorblade/skills](https://github.com/rustyrazorblade/skills)

**Style:** Heavy live demo — Claude Code open on screen throughout Parts 5-8.

> **Platform:** this runs on **OpenShift 4.19 on IBM Cloud** (the EKS request was declined).
> Three platform differences change what is on screen, and each is worth naming rather than
> hiding — they are all good teaching moments:
> - **Racks map to nodes, not AZs.** This cluster has no zone labels at all.
> - **Backups go to NooBaa**, OpenShift's in-cluster S3, not AWS S3. No IAM to request.
> - **Everything is exposed by Route**, not a load balancer. The MCP endpoint is real https.
>
> The ring is 3 nodes scaling to 6, not 6 to 9 — the cluster has three Cassandra workers.

> The event was sold on *"a clear introduction to k8ssandra, what it is, why it
> matters, and how it fits into modern Cassandra operations."* Parts 4 and 5 are
> 24 minutes — 40% of the talk — and exist to deliver exactly that. The MCP and
> skills material grows in absolute terms (8 min → 15 min) but stops being the
> whole talk.

## Time budget

| # | Section | Min | Running |
|---|---|---:|---:|
| 0 | Cold open — the cluster is already running | 3 | 3 |
| 1 | Opening — the Cassandra consultant's journey | 2 | 5 |
| 2 | Hand-editing YAML: the dark ages | 3 | 8 |
| 3 | Cassandra meets Kubernetes: hope and pain | 4 | 12 |
| 4 | **★ The k8ssandra project** | 12 | 24 |
| 5 | **★ The whole suite, live** | 12 | 36 |
| 6 | Scale under load: 3 → 6 | 6 | 42 |
| 7 | easy-cass-mcp: giving AI eyes on your cluster | 7 | 49 |
| 8 | Skills: Cassandra expertise as markdown | 8 | 57 |
| 9 | Closing — the stack of the future | 3 | 60 |

**Pre-show state (see README step 6 and the runbook at the end):** ring at `size: 6`,
dataset preloaded, NoSQLBench running for ~60 min so throughput has settled, Grafana
and Reaper tabs open and logged in, MCP verified from Claude Code.

---

## Part 0 (~3 min) — Cold Open: The Cluster Is Already Running

Open on a terminal, not a slide.

```bash
kubectl get pods -n default -o wide
```

Point at what is on screen, in this order:
- **3 Cassandra pods**, named `demo-dc1-rack1-sts-0`, `rack2`, `rack3` — three racks
- A **medusa sidecar** in every Cassandra pod
- A **Reaper** pod
- **easy-cass-mcp**
- Over in `monitoring`: **Prometheus and Grafana**

```bash
kubectl get nodes -L workload,k8ssandra.io/rack
```

- Three workers labelled `rack1`, `rack2`, `rack3`
- One node tainted `workload=loadgen` — nothing but the load generator runs there
- One `utility` node carrying Prometheus, Grafana, Reaper and the operators

Then switch to the Grafana tab, already showing an hour of history at
«MEASURE AT REHEARSAL» ops/sec.

> _"Everything you're about to see is live. It's been running for an hour, it's
> under load right now, and I'm not going to stop it for the rest of the talk."_

---

## Part 1 (~2 min) — The Cassandra Consultant's Journey

- Speaker intro: background as a Cassandra consultant
- Thesis: AI tooling is changing how we operate databases — but there are multiple
  approaches with real tradeoffs
- Roadmap: hand-editing → operators → the k8ssandra project → MCP → skills
- _"By the end of this talk I'm going to double the size of this cluster and kill a
  node, in front of you, while a load test is running — and then ask Claude what
  happened."_

---

## Part 2 (~3 min) — Hand-Editing YAMLs: The Dark Ages

- Life as a C* consultant: `cassandra.yaml`, `cassandra-env.sh`, `jvm.options` —
  across N nodes, by hand
- Seed lists, rack assignments, snitch configs, GC tuning — all bespoke per cluster
- Config drift is the real enemy: one wrong indent and a node won't join the ring
- Rolling restarts: SSH into each node in order, pray nothing times out, repeat
- _"I've seen more YAML than my family"_

---

## Part 3 (~4 min) — Cassandra Meets Kubernetes: Hope and Pain

- **The promise:** declarative infrastructure, self-healing, automated scaling
- **Early attempts:** hand-rolled StatefulSets, init containers for seed discovery,
  manual PV lifecycle
- **The hardest problems:**
  - Storage: PVCs don't follow pods; lose a node, orphan a volume
  - Rolling restarts: Kubernetes doesn't know about Cassandra's streaming/repair state
  - Rack-aware scheduling: node labels, pod anti-affinity rules, token math — all by hand
- **Config management helped, but only halfway:** Ansible, Terraform, Puppet are
  still *imperative* at heart. They get you to a desired state; they don't *keep*
  you there. A dead node is still a dead node waiting for a human and a playbook run.
- **The gap this leaves:** you can automate the deploy and still have nothing that
  runs repairs, takes backups, or tells you the cluster is unhealthy.

_Keep this tight — it is setup for Part 4, not a destination._

---

## Part 4 (~12 min) — ★ The k8ssandra Project

**This is the segment the event was sold on. It does not currently exist anywhere
else in the repo — build slides for it.**

### 4a. What k8ssandra is, and isn't (~2 min)

- An **umbrella project**, not a single operator
- **Not** a fork of Cassandra. **Not** a distribution. It runs stock Apache
  Cassandra — the exact 5.0.8 you'd download — with operators around it
- Lineage: born out of the DataStax Kubernetes work, now a community project; the
  same engineering that underpins Mission Control

### 4b. The components (~3 min)

| Component | What it does |
|---|---|
| **cass-operator** | Owns the ring: StatefulSets, seed discovery, rack placement, rolling restarts that understand Cassandra's state |
| **k8ssandra-operator** | Owns the *suite*: reconciles one `K8ssandraCluster` CR into cass-operator resources plus everything below |
| **management-api** | Sidecar in every Cassandra pod — the HTTP control plane the operators actually drive (this is what replaced shelling into `nodetool`) |
| **Reaper** | Anti-entropy repair orchestration |
| **Medusa** | Backup and restore to object storage |
| **metrics agent** | Prometheus endpoint, no JMX exporter to hand-roll |
| **k8ssandra-client** | CLI for the bits that don't belong in a CR |

**Stargate — name it, and be straight about it.** It was the project's data-API
gateway (REST, GraphQL, gRPC over Cassandra). It is **deprecated, and it does not
work with Cassandra 5.0+**. The operator emits a deprecation warning if you set the
field. It is not deployed in this workshop.

> _"I could have quietly left that off the slide. But a project that retires
> something and tells you clearly is a project you can plan around."_

### 4c. The CRD map, live (~3 min)

Show `docs/architecture-diagrams.md` §4 on screen, then go to the terminal:

```bash
kubectl get crds | grep -E 'k8ssandra|cassandra\.datastax'
kubectl explain k8ssandracluster.spec
```

Point out the CRD *groups* — `k8ssandra.io`, `cassandra.datastax.com`,
`medusa.k8ssandra.io`, `reaper.k8ssandra.io`, `control.k8ssandra.io` — and that
every one of them is now instantiated in this cluster, not just installed.

### 4d. Why it matters (~2 min)

Put the CR on screen next to what it replaces:

- **One `K8ssandraCluster` CR, ~150 lines including comments** →
  StatefulSets, headless services, the superuser secret, PVC lifecycle, rack
  placement, a repair scheduler, a backup pipeline, and ServiceMonitors
- The rack block is six lines. That's the token math from Part 2, gone
- The ceiling: control-plane / data-plane split gives you multi-DC and
  multi-cluster from the same CR shape

### 4e. Governance and cadence (~2 min)

- **v1.33.0 released 2026-09-03** — shipping Reaper 5.0.1, Medusa 0.30.1,
  cass-operator 1.32.0
- Its entire changeset that release was Medusa and Reaper fixes — the two
  components we're about to demo. That's what an actively maintained project looks like
- Pin your versions. This workshop pins all four Helm charts, and the reason is
  boring and important: an unpinned chart that bumps between rehearsal and showtime

---

## Part 5 (~12 min) — ★ The Whole Suite, Live

**Also new. Last time the talk claimed "batteries included" in a single bullet and
deployed none of them.**

### 5a. Monitoring (~4 min)

```bash
kubectl get servicemonitor -n default
```

- The operator wrote that, from **four lines** of `telemetry:` in the CR
- No JMX exporter sidecar, no scrape config, no relabeling rules

Switch to Grafana: throughput, p99 read and write latency, pending compactions,
per-pod CPU, disk used per pod.

- **Gotcha worth 20 seconds on screen:** every published k8ssandra Grafana dashboard
  targets the deprecated MCAC endpoint (`collectd_mcac_*`). Cassandra 5 exposes
  `org_apache_cassandra_metrics_*` through the management API. Grab a community
  dashboard and every panel renders empty. This one was built against the live names.

### 5b. Reaper (~4 min)

Port-forward is already up; go to the tab.

- The cluster **registered itself** — nothing was configured
- **Why repairs exist**, briefly and concretely: replicas drift because writes
  fail, hints expire, and nodes miss mutations while down. If a deleted row isn't
  repaired before `gc_grace_seconds`, the tombstone is collected and the row comes
  back from a replica that never heard about the delete. That's zombie data.
- **Trigger a full repair on `baselines` live.** Watch segments tick up.
- Leave it running — come back to it in Part 8.

### 5c. Medusa (~4 min)

```bash
kubectl apply -f manifests/cassandra/medusa-backup-job.yaml
kubectl get medusabackupjob -n default -w
```

Talk while it uploads (~«MEASURE AT REHEARSAL»):
- **The bucket is in-cluster.** NooBaa — OpenShift Data Foundation's S3 gateway —
  provisioned it from a nine-line ObjectBucketClaim. No AWS account, no IAM request,
  no ticket to a cloud team. Medusa just sees an S3 endpoint.
- Worth naming: Medusa is configured `s3_compatible` rather than `s3`, because
  NooBaa speaks the API without being AWS. That portability is the point.
- `backupType: full` so every sstable re-uploads and you can actually watch it

Then the payoff:

```bash
kubectl get medusabackup -n default
kubectl get objectbucketclaim medusa-backups -n default
```

Per-node backup sizes, in object storage that did not exist ten minutes ago.

---

## Part 6 (~6 min) — Scale Under Load: 3 → 6

If you take one thing from this session: **scaling Apache Cassandra under load is
no longer an event.**

```bash
kubectl patch k8ssandracluster demo -n default --type=json \
  -p='[{"op":"replace","path":"/spec/cassandra/datacenters/0/size","value":6}]'
```

**Start it, then talk over it** — bootstraps are serial and this takes ~6-7 minutes.
Material to fill the time:

- Each rack goes 1 → 2. `size` must be a multiple of 3 or the racks go unbalanced
- **Be straight about the compromise.** This cluster has three Cassandra workers, so
  doubling the ring means two replicas land on each node. For an RF=3 keyspace at
  LOCAL_QUORUM, losing one node now costs two of three replicas. You would not do
  this in production — and the `/expert` skill says exactly that, which is a nice
  set-up for Part 8. Say it out loud; the audience has three-node clusters too.
- **Rack-aware placement is the thing that failed last time.** Two racks, and
  Cassandra's default `allocate_tokens_for_local_replication_factor=3` couldn't
  allocate tokens — bootstrap just stalled. Worth telling as a failure, because it's
  the kind that looks like a hang, not an error.
- **And racks don't have to be AZs.** This cluster has no zone labels at all, so the
  racks here are three worker nodes with a label I applied. A rack is a *logical*
  failure domain — map it to whatever your real one is. That reframing is the most
  portable idea in this section.
- **Zero-Copy Streaming**: sstables stream at the file level, not row by row.
  Last run: 42-138 MB per node in 6.7-9.8 seconds
- What the operator is doing: one node at a time, waiting for each to finish joining
  before starting the next — the thing you used to do by hand with a runbook and a
  Slack thread

Come back at the end of Part 7 for `nodetool status` and the ownership shift.

**Expected (re-measure at rehearsal):** rate held within 1%, zero NB errors, RF=3
maintained throughout, ownership settling from 100% to ~50% per node.

---

## Part 7 (~7 min) — easy-cass-mcp: Giving AI Eyes on Your Cluster

- **What is MCP?** (30 seconds) — Model Context Protocol: a standard for giving AI
  models access to external tools. Server exposes tools → Claude calls them →
  results flow back as context.
- **easy-cass-mcp:** domain-specific MCP server that speaks CQL fluently, deployed
  in-cluster. Claude Code → OpenShift Route (edge TLS) → easy-cass-mcp pod → Cassandra pods.

  | Tool | What it does |
  |---|---|
  | `query_all_nodes(cql)` | Fans out a CQL query to every replica, labels results by node — essential for the `system_views.*` per-node virtual tables |
  | `query_node(addr, cql)` | Targets a single replica for deep dives |
  | `query_system_table(keyspace, table)` | Curated access to system keyspaces (peers, local, sstable_activity, ...) |
  | `get_create_table(keyspace, table)` | Pulls canonical schema — feeds data-model analysis |
  | `analyze_table_optimizations(keyspace, table)` | Version-aware compaction recommendations |

- **Build narrow, not wide:**
  - Tried a generic Kubernetes MCP server first — a single `get pods` dumps
    thousands of tokens of labels, annotations, status conditions
  - easy-cass-mcp returns only what's relevant, structured by node
  - **Takeaway: MCP server *design* matters as much as MCP server existence.**

### Live Demo — Node Restart Under Load

_The load test is still running. The ring just went to 9._

**Step 1 — "Is the cluster healthy?"**
Claude calls `local_read_latency` / `local_write_latency` across all nodes. Show the
even distribution — and that the three newest nodes have lower counts because they
only just joined.

**Step 2 — Kill a node, live:**
```bash
kubectl delete pod demo-dc1-rack2-sts-0
```

**Step 3 — "What do you see now?"**
Claude re-queries and surfaces the anomaly: surviving nodes in the hundreds of
thousands of ops, the restarted node at a fraction of that and ramping. It
interprets it as a recent restart, not a fault, and notes the load test never
dropped a query.

**The point:** in the old world that was a maintenance window, a runbook, and a
Slack thread. Here it's a 52-second demo with a natural-language debrief.

---

## Part 8 (~8 min) — Skills: Cassandra Expertise as Markdown

- **What is a skill?** A markdown file with trigger conditions and instructions,
  loaded into Claude Code's context on demand. No running service, no deployment.

  | | MCP Server | Claude Code Skill |
  |---|---|---|
  | **What it is** | Running service exposing tools via protocol | Markdown file with instructions |
  | **Where it runs** | Separate process or container | Loaded into the agent's context window |
  | **What it provides** | Live data access (query, mutate) | Domain knowledge and procedures |
  | **Context cost** | Each tool call's results fill the window | Loaded once when triggered |
  | **Maintenance** | Write code, deploy, monitor a service | Edit a markdown file |
  | **Best for** | Real-time data, actions with side effects | Runbooks, deployment playbooks, troubleshooting |
  | **Limitation** | Generic servers bloat context; needs infra | No live data access; static knowledge only |

- **Together:** MCP is the data plane (what's happening right now); skills are the
  control plane (what to do about it). The skill tells Claude *how*; MCP lets Claude
  *verify*.

### Three Cassandra skills, three lenses ([rustyrazorblade/skills](https://github.com/rustyrazorblade/skills))

| Skill | Lens | Output style |
|---|---|---|
| `/diagnose` | USE method (Utilization / Saturation / Errors) across all nodes | "Here's what's wrong (or right) and why" |
| `/optimize` | Tier-ranked tuning: `cassandra.yaml` + `ALTER TABLE` deltas | "Apply these in order, expected impact: X" |
| `/expert` | Opinionated big-picture — anti-patterns, trade-offs, production-readiness | "Here's what I'd actually do, and why" |

These aren't generic "ask an LLM" wrappers. They apply USE-method diagnostics,
published Cassandra-community stances on `num_tokens` and compaction, and
version-specific C* 5 features (UCS, Trie memtables, BTI, Zero-Copy Streaming) —
codified once, applied every time.

### The callback — what the skills found last time, and what we did about it

**This is the strongest ~3 minutes in the talk. It needs both numbers, so capture
the "before" at rehearsal before raising the limits.**

Last run, `/diagnose` fanned out via `query_all_nodes` against `system_views.*` and
compared all 9 nodes. The headline find:

> Pods pegged at **6.0 / 6.0 CPU**, EC2 hosts at **30-70%**, and **zero pending
> thread-pool tasks**.

That is CFS throttling at the cgroup level — invisible to `nodetool tpstats`,
invisible to a flat dashboard. It accounted for the ~8k ops/sec gap between the
100k target and the ~92k achieved.

`/optimize` then tier-ranked the fixes. The Tier-1 surprise: the operator default
ships `key_cache_size_in_mb: 0`, while the table requests `caching: {keys: ALL}` —
the table-level setting is silently meaningless without the YAML setting.

**What this cluster does differently, because of that analysis:**

| Finding | Change in the repo |
|---|---|
| CFS throttling at the cgroup ceiling | **No CPU limit at all** — the quota mechanism isn't installed |
| `key_cache_size_in_mb: 0` vs `caching: {keys: ALL}` | `key_cache_size_in_mb: 200` |
| 16 KiB compression chunks, ~250x I/O amp on point lookups | `chunk_length_in_kb: 4` |
| Soft anti-affinity that no-ops when every node has a Cassandra pod | Dedicated **tainted** loadgen node |
| `softPodAntiAffinity` — `/expert` called it "defensible only for dev/CI/workshop, not for any RF=3 cluster where availability matters" | **Three racks, and the skill's objection now stated out loud rather than quietly ignored** — see the note below |

**The one the skill is still right about.** Four of those five are fixed. The fifth —
`softPodAntiAffinity` — is still on, because three Cassandra workers cannot host a
six-node ring any other way. Rather than hide it, put it on screen: the skill's
critique is correct, the constraint is real, and the honest answer is "this is a
workshop cluster, and here is exactly what I would change in production."

That is a better ending than a clean sweep would have been. A tool that tells you
something inconvenient, that you then choose to accept with your eyes open, is more
useful than one that only confirms what you already did.

Run `/diagnose` live against the current cluster and show the difference.

> _"The operator defaults shipped five production tunings missed. The MCP-plus-skills
> loop surfaced all of them in under an hour — and then I went and fixed them, and
> the fixes are in the repo."_

**Check Reaper here** — the repair from Part 5b should have made real progress.

- **Two skills, two scopes — same mechanism:**
  - `cassandra-k8s-deploy`: general expertise, taken everywhere — EKS/GKE/AKS,
    Medusa, Reaper, TLS, auth
  - `k8ssandra-workshop`: project-specific runbook for this repo — exact manifests,
    namespaces, MCP tool selection, load-test procedures
  - The project-specific one explicitly supersedes the general one in this repo

---

## Part 9 (~3 min) — Closing: The Stack of the Future

- **The full picture:**
  - **k8ssandra** manages the cluster — ring, repairs, backups, metrics
  - **MCP** gives AI live access to what it's actually doing
  - **Skills** give AI the knowledge to reason about what it sees
- **Three things to take home:**
  1. Build domain-specific MCP servers, not generic ones. Context windows are precious.
  2. Turn your runbooks into skills. If you wrote it down, Claude can follow it.
  3. Combine both: MCP for observation, skills for action.
- _"The operator alone manages the cluster. The full loop *operates* it."_
- **Links:** workshop repo (QR slide),
  [easy-cass-mcp](https://github.com/rustyrazorblade/easy-cass-mcp),
  [skills](https://github.com/rustyrazorblade/skills)
- Q&A

---

## Day-of runbook

Full detail in the README; this is the timing skeleton.

| Clock | Action |
|---|---|
| T-180 | `kubectl get nodes -L topology.kubernetes.io/zone,workload` — assert 3/3/3 + tainted loadgen. **Hard gate.** |
| T-178 | `./manifests/openshift/node-labels.sh` then `./scripts/deploy-openshift.sh` |
| T-148 | Assert rack balance (1/1/1 at size 3); `kubectl get servicemonitor` non-empty; Grafana Route reachable |
| T-143 | Verify MCP tools respond from Claude Code |
| T-135 | `nosqlbench-prepare-job` — schema + bulk load |
| T-117 | **Pre-flight Medusa backup** to prove the NooBaa path, then delete it so the live one is a genuine first full backup |
| T-109 | **Pre-flight Reaper repair** to ~20%, then abort — proves registration and `reaper_db` migration |
| T-103 | Start the main NoSQLBench job |
| T-100 → T-40 | **Soak.** Throughput settles, driver pool warms, Grafana accumulates history. Touch nothing. |
| T-40 | Confirm sustained ops/sec. If it's short of target, lower `cyclerate` now rather than demoing a miss |
| T-25 | Open the Routes in browser tabs and confirm they load. No port-forwards to babysit on OpenShift — that is one fewer thing to fail live |
| T-20 | Screenshot every live moment as a backup slide; Zoom share test at presentation font size |

**The pre-warm rule:** anything that can fail *silently* (Medusa credentials, Reaper
schema migration, ServiceMonitor discovery, MCP connectivity) gets proven before the
audience arrives. Anything whose *duration is the point* (the backup upload, the
repair progress bar, the 6→9 bootstrap) is done live. The backup and the repair each
run twice — once quietly to prove the plumbing, once on camera.

**Numbers marked «MEASURE AT REHEARSAL» must be filled in before the talk.** Do not
quote the old run's figures for the new cluster — it has different CPU limits,
different anti-affinity, and three racks.

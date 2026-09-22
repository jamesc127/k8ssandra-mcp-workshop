# Control C* Con Claude Code: k8ssandra, MCP, and Skills

**Event:** [Planet Cassandra #18](https://luma.com/1osqeg4d) — Zoom webcast
**Format:** 60-minute talk + live demo, ~10 min Q&A
**Repo:** k8ssandra-workshop
**Companion repos:**
- MCP server: [rustyrazorblade/easy-cass-mcp](https://github.com/rustyrazorblade/easy-cass-mcp)
- Skills: [rustyrazorblade/skills](https://github.com/rustyrazorblade/skills)

**Style:** Heavy live demo — Claude Code open on screen throughout Parts 5-8.

> **Presenting from this?** Don't. `docs/talk-track.md` is the run sheet — the beats,
> the measured durations, what to say while each one runs, and the failure playbook.
> This document is the design: why each segment exists and what was measured to get
> there. Keep the track on your second screen; read this one beforehand.
>
> ⚠️ **The track was simplified on 22 Sep and is now authoritative on sequencing.** It
> runs **five** live demos — backup, scale, MCP, node kill, skills — against a load test
> that is simply always there. The Part numbering and time budget below still describe
> the older, busier structure and have NOT been reconciled. Where the two disagree,
> **the track wins.** Specifically, these are no longer live demo segments:
> - **Reaper** — the repair runs in the background from before the talk and is used as
>   one line during the node kill ("the repair didn't even notice"). It is not a beat.
> - **Monitoring / ServiceMonitor** — folded into the k8ssandra section as "four lines
>   of `telemetry:` produced all of this", shown on Grafana rather than demoed.
> - **The live CRD map query** — a slide, not a live call.
>
> That buys the k8ssandra explainer **14 minutes** instead of 12, which is the segment
> the event was actually sold on.

> **Everything on this outline is driven from Claude Code in natural language.** There is
> no terminal typing in this talk. Claude is connected to two things at once: the
> **OpenShift cluster** (kubectl/oc, for pods, nodes, CRDs, scaling, killing things) and
> the **easy-cass-mcp server** (for anything Cassandra-internal — `nodetool`-equivalents,
> `system_views.*`, schema). Every command block below is written as **the prompt to
> type**, not the command to run.
>
> Three presenter notes about working this way live:
> - **Say what you asked for out loud** before you hit enter. The audience reads the
>   prompt; you narrate the intent.
> - **Let them watch the tool calls.** The interesting part is often *which* tool Claude
>   reaches for — MCP for ring state, kubectl for pod state. That split is Part 7's whole
>   argument, made visible for free.
> - **Have the fallback command in your notes.** If Claude picks a wrong approach on
>   stage, you correct it in one sentence and move on — that is a better demo than a
>   flawless one, but only if you know the answer.

> **Platform:** this runs on **OpenShift 4.19 on IBM Cloud** (the EKS request was declined).
> Three platform differences change what is on screen, and each is worth naming rather than
> hiding — they are all good teaching moments:
> - **Racks map to nodes, not AZs.** This cluster has no zone labels at all.
> - **Backups go to in-cluster S3** (MinIO on Ceph), not AWS S3. No IAM to request.
> - **Everything is exposed by Route**, not a load balancer. The MCP endpoint is real https.
>
> The ring is 3 nodes scaling to 6, not 6 to 9 — the cluster has three Cassandra workers.

## Live endpoints

All three are OpenShift Routes with **edge TLS**, so they are real `https://` — no
port-forward, no `--allow-http`, nothing to babysit. Have all three open in tabs and
logged in before you go live.

| What | URL |
|---|---|
| **Grafana** | https://grafana-monitoring.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com |
| **Reaper** | https://reaper-default.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com |
| **easy-cass-mcp** | https://easy-cass-mcp-default.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com/mcp/ |
| **OpenShift console** | https://console-openshift-console.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com |

Notes that will save you on the day:

- **The MCP URL needs the trailing `/mcp/`.** For Claude Desktop the bridge is
  `npx mcp-remote https://easy-cass-mcp-default.../mcp/` with **no** `--allow-http` —
  the Route terminates TLS. That flag is an EKS-only leftover and it will break this.
- **Prometheus has no Route** — it is ClusterIP only
  (`kps-kube-prometheus-stack-prometheus.monitoring:9090`). Everything metrics-facing
  goes through Grafana. That is *why* the Grafana MCP server is the right tool here:
  it proxies PromQL through Grafana's datasource API, so Prometheus never needs
  exposing and there is no port-forward to babysit.
- **These hostnames contain the TechZone cluster id `itz-ckzpiv`.** Rebuild or get
  reassigned a different cluster and every URL here changes. Re-derive them with
  _"list the Routes and give me their hostnames"_ rather than trusting this table.

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

**Pre-show state (see README step 6 and the runbook at the end):** ring at **`size: 3`**
— Part 6 scales it to 6 live, so it must start at 3 — dataset preloaded, NoSQLBench
running for ~60 min so throughput has settled, Grafana and Reaper tabs open and logged
in, both MCP servers verified from Claude Code.

---

## Part 0 (~3 min) — Cold Open: The Cluster Is Already Running

Open on a terminal, not a slide.

> **Ask Claude:** _"Show me every pod in the default namespace, with the node each one
> landed on. Group them by what they actually are."_

Point at what is on screen, in this order:
- **3 Cassandra pods**, named `demo-dc1-rack1-sts-0`, `rack2`, `rack3` — three racks
- A **medusa sidecar** in every Cassandra pod
- A **Reaper** pod
- **easy-cass-mcp**
- Over in `monitoring`: **Prometheus and Grafana**

> **Ask Claude:** _"List the worker nodes with their `workload` and `k8ssandra.io/rack`
> labels, and tell me which ones are tainted and with what."_

- Three workers labelled `rack1`, `rack2`, `rack3`
- One node tainted `workload=loadgen` — nothing but the load generator runs there
- One `utility` node carrying Prometheus, Grafana, Reaper and the operators

Then switch to the Grafana tab, already showing an hour of history at
**~52,500 ops/sec** (measured 22 Sep on the corrected dataset: 44,648 read + 7,879
write, an 85/15 mix, zero errors).

> 🎯 **Decided 22 Sep: `cyclerate` stays at 60000.** The cluster sustains ~52.5k
> because it is CPU-pegged at the 14-core limit, so the graph sits ~13% under its own
> target. **That gap is the point, not a blemish.** Name it in Part 0 — "we're asking
> for 60k, getting 52.5k, and nothing is failing" — and it becomes the setup that Part 6
> pays off when doubling the ring closes it, and that Part 8 explains when `/diagnose`
> finds the cgroup ceiling.
>
> A flat line that meets a lowered target demos nothing. A shortfall you diagnose and
> then fix with capacity is the whole talk in one number.

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

Show `docs/architecture-diagrams-openshift.md` on screen — §2 for the workload
layout and §4 for the CRD ownership map — then ask Claude to do the same thing against
the live cluster:

> **Ask Claude:** _"Which K8ssandra and cass-operator CRDs are installed on this cluster?
> Group them by API group, and mark which ones actually have instances right now."_

That second half is the line worth asking for — "installed" and "instantiated" are
different claims, and this is the one slide where you can show both at once.

> **Ask Claude:** _"Now walk me through the top-level fields of the K8ssandraCluster spec,
> and show me which of them our `demo` CR actually sets."_

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

> **Ask Claude:** _"Is there a ServiceMonitor in the default namespace? Show me what owns
> it, which endpoint it scrapes, and the four lines of the CR that caused it to exist."_

- The operator wrote that, from **four lines** of `telemetry:` in the CR
- No JMX exporter sidecar, no scrape config, no relabeling rules

Switch to [Grafana](https://grafana-monitoring.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com):
throughput, p99 read and write latency, pending compactions, per-pod CPU, disk used per pod.

- **Gotcha worth 20 seconds on screen:** every published k8ssandra Grafana dashboard
  targets the deprecated MCAC endpoint (`collectd_mcac_*`). Cassandra 5 exposes
  `org_apache_cassandra_metrics_*` through the management API. Grab a community
  dashboard and every panel renders empty. This one was built against the live names.

### 5b. Reaper (~4 min)

The [Reaper Route](https://reaper-default.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com)
is already open in a tab — go to it. (No port-forward to babysit on OpenShift; that is
one fewer thing to fail live.)

- The cluster **registered itself** — nothing was configured
- **Why repairs exist**, briefly and concretely: replicas drift because writes
  fail, hints expire, and nodes miss mutations while down. If a deleted row isn't
  repaired before `gc_grace_seconds`, the tombstone is collected and the row comes
  back from a replica that never heard about the delete. That's zombie data.
- **Trigger a full repair on `payments` live** from the Reaper UI. Watch segments tick up.
  If you would rather stay in Claude Code, ask instead: _"Has Reaper registered this
  cluster? Show me its current repair runs and the segment progress on each."_
- Leave it running — come back to it in Part 8.

**MEASURED 21 Sep**, full (non-incremental) repair of `payments`, idle 6-node ring:

| | |
|---|---|
| Total segments | **436** across the three tables |
| Rate | **~2.0 segments/min** |
| Projected full run | **~3.6 hours** |
| After 10 min | 21 segments, 4.8% |

**Do not apologise for that number — it is the entire argument for Reaper.** A full
repair of 50 GB is a multi-hour operation that must be split into hundreds of
resumable segments, paced so it does not compete with production traffic, and
survive a node restarting underneath it. That is a job you do not want to run by
hand from a terminal, and it is exactly what Reaper does unattended. If the bar were
"finishes during a conference talk", nobody would need the tool.

What the audience should see is **segments incrementing roughly every 30 seconds**,
which is plenty to make the point on screen.

**Two caveats for the day:**
- These numbers are from an **idle** ring at size 6. During the talk NoSQLBench is at
  60k ops/sec and Part 5b runs at **size 3**, so expect it to be slower, not faster.
- **Reaper keeps its state in `reaper_db` inside the cluster**, so it is sensitive to
  the cluster going away — but far less than you would expect. Two different events,
  two different outcomes, both measured 21 Sep:

  | Event | Reaper | The repair |
  |---|---|---|
  | **Force-kill one node** (`--grace-period=0 --force`) — what Part 7 does | **no restart** | **never paused.** Segments kept incrementing straight through: 22 → 23 → 24 … at the same ~2/min |
  | **Rolling restart of every pod** (a CR edit) | exits, code 1 after 9 s, recovers on its own | resumes from the last completed segment |

  **The first row is the one worth saying out loud in Part 7.** You kill a node in
  front of the audience while a repair is running, and the repair does not notice.
  That is segmented, resumable, coordinated repair doing exactly what it exists to
  do — and it is a stronger claim than the node-restart timing on its own.

### 5c. Medusa (~4 min)

> **Ask Claude:** _"Start a full Medusa backup from
> `manifests/cassandra/medusa-backup-job.yaml`, then keep an eye on the MedusaBackupJob
> and tell me as each node finishes."_

**Timing, measured 21 Sep:** a full backup of a loaded **6-node** ring took
**8 min 38 s** — 47.84 GB across 4,732 files. Part 5c runs at **size 3**, so expect
roughly **4–5 minutes**. That fits the segment, but only just: start it *first*, then
talk. Do not start it after the explanation.

Talk while it uploads:
- **The S3 endpoint is in-cluster.** MinIO, on a Ceph RBD volume, in the same
  namespace as Cassandra. No AWS account, no IAM request, no ticket to a cloud team.
  Medusa just sees an S3 endpoint.
- Worth naming: Medusa is configured `s3_compatible` rather than `s3`, with an
  explicit host instead of an AWS region. **That is the portability, and it is
  load-bearing rather than decorative** — the same five lines point at MinIO, AWS S3,
  GCS or anything else that speaks the API. It is the reason this workshop can run
  on a cluster with no cloud account attached to it at all.
- `backupType: full` so every sstable re-uploads and you can actually watch it
- The sidecar doing the work is the **medusa container inside every Cassandra pod** —
  point at it in the Part 0 pod list. Backup is not a separate system to operate

Then the payoff:

> **Ask Claude:** _"Show me the finished MedusaBackup objects with the per-node sizes,
> and how much is now sitting in the MinIO bucket."_

Per-node backup sizes, in object storage that did not exist ten minutes ago.

> **If someone asks "why not ODF's own object gateway?"** — and on an OpenShift
> audience someone will — the honest answer is that it was tried and it could not
> carry the load. ODF's Multicloud Object Gateway serves buckets from pods its
> operator pins at 400Mi, and a full backup of this ring OOMKilled them roughly 75
> seconds in. Three mitigations were measured and all failed; the limit is not
> exposed by any CRD. `docs/TROUBLESHOOTING.md` has the numbers if you want to be
> precise. **Have the answer ready; do not put it on a slide** — it is a good answer
> to a question and a distraction as a bullet.

---

## Part 6 (~6 min) — Scale Under Load: 3 → 6

If you take one thing from this session: **scaling Apache Cassandra under load is
no longer an event.**

> **Ask Claude:** _"Scale the `demo` K8ssandraCluster from 3 nodes to 6."_

**Watch which patch it chooses** — this is worth ten seconds of narration. A
strategic-merge patch replaces the whole datacenter array and gets rejected with
"storageConfig must be defined"; the edit has to be a JSON patch targeting
`/spec/cassandra/datacenters/0/size`. It is a genuinely non-obvious Kubernetes trap, and
watching it get picked correctly is more convincing than asserting it on a slide.

Then hand Claude the job of narrating the bootstrap for you:

> **Ask Claude:** _"Watch the scale-up. Every 30 seconds tell me the ring status, which
> node is currently joining, and whether NoSQLBench throughput has dipped."_

**Start it, then talk over it** — bootstraps are serial and this takes **9 min 20 s**
(measured, not the ~6-7 min previously assumed). Part 6 is budgeted 6 minutes, so the
scale finishes roughly 3 minutes INTO Part 7. That is fine by design — but it means
**do not force-kill a node in Part 7 until the ring is 6/6 UN.** See `docs/talk-track.md`.
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

Come back at the end of Part 7 for the ownership shift:

> **Ask Claude:** _"Give me the ring status — every node, its rack, its load, and
> what percentage of the token range it owns."_

**MEASURED, 17 Sep rehearsal** — these are real numbers from this cluster, not
estimates:

| | |
|---|---|
| Patch to 6 nodes `UN` | **9 min 20 s** |
| First new node joined | ~2 min |
| Throughput | 55.5k - 60.1k against a 60k target |
| Worst dip | **8%**, transient, recovered inside 25 s |
| NoSQLBench errors | **0** |
| Ownership | 100% -> 51.5% / 48.5% |

> ⚠️ **The throughput figures in this table are from BEFORE 22 Sep**, i.e. from the
> dataset whose partitions held 1.4 rows. The **timings and the dip percentages are
> still good** — they are ring and streaming mechanics, not query mechanics — but do
> not quote the absolute ops/sec from here alongside the corrected numbers elsewhere.
> Tomorrow's run-through re-measures them.

The best visual is a `nodetool status` taken mid-scale, when the racks have not
yet caught up with each other:

```
UN  10.129.2.174   11.11 GiB   owns 51.5%    rack1   original
UN  10.131.0.93    11.09 GiB   owns 51.5%    rack2   original
UN  10.131.2.38    11.05 GiB   owns 100.0%   rack3   original - not yet split
UN  10.131.0.94     5.37 GiB   owns 48.5%    rack2   NEW, joined
UN  10.129.2.175    1.71 GiB   owns 48.5%    rack1   NEW, still filling
```

One rack still at 100% while the others have already halved, and two new nodes
at different fill levels. That single screen says more about what the operator is
doing than any slide would.

**A caveat worth saying out loud.** The scale succeeded and the load never saw an
error — but the `server-system-logger` sidecar OOMKilled on several pods during
it (128 MiB limit, 122 MiB steady state). Cassandra was untouched at ~9.9 GiB of
its 32 GiB limit and never left the ring, yet those pods reported **2/3 Ready**.

That is the exact inverse of the disk-full failure in Part 8, where the pod said
3/3 Running and Cassandra was dead. Pod readiness was wrong in both directions,
for opposite reasons. The limit is now 256 MiB.

---

## Part 7 (~7 min) — easy-cass-mcp: Giving AI Eyes on Your Cluster

- **What is MCP?** (30 seconds) — Model Context Protocol: a standard for giving AI
  models access to external tools. Server exposes tools → Claude calls them →
  results flow back as context.
- **easy-cass-mcp:** domain-specific MCP server that speaks CQL fluently, deployed
  in-cluster. Claude Code → OpenShift Route (edge TLS) → easy-cass-mcp pod → Cassandra pods.
  The endpoint is
  `https://easy-cass-mcp-default.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com/mcp/`
  — worth putting on the slide, because "the MCP server is a URL your agent dials" is the
  whole architecture in one line.

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

### A second MCP server, and why it matters more than it looks

Also connected: **[grafana/mcp-grafana](https://github.com/grafana/mcp-grafana)**,
Grafana Labs' own server. Run read-only — a Viewer service account, `--disable-write`,
and the tool surface trimmed from ~60 to 17.

Three reasons it earns its slide:

- **It is not mine.** Everything else on stage is something I built. This is a vendor
  arriving at the same pattern independently, which is the difference between "here is
  my clever setup" and "here is where the ecosystem is going."
- **It solves a real constraint.** Prometheus on this cluster is ClusterIP with no
  Route. The server proxies PromQL *through* Grafana's datasource API, so it needs
  only the Grafana URL and a token — nothing new exposed.
- **It spans both layers.** It can reach our kube-prometheus-stack *and* OpenShift's
  Thanos. That is Part 8's two-layer argument with the agent as the thing that spans
  them, instead of you alt-tabbing between dashboards.

> **The story worth telling, because it is true and it is recent.** Within ten minutes
> of being connected, it caught a wrong number on this deck. Slide 17 claimed Cassandra
> was pegged at 14/14 CPU. It was not — OpenShift's Thanos returns two identical
> cAdvisor series per container, the panel summed them, and every CPU and memory reading
> was double. The tell was already on the slide: the worker-node panel disagreed, and
> had for days. **Three sources agreed only after I asked something that made me check.**
>
> That is the honest version of the whole talk. Not "the AI was right" — the AI made a
> claim I could check against two other sources, and checking is what found it.

### Live Demo — Node Restart Under Load

_The load test is still running. The ring just went to 6._

**Step 1 — "Is the cluster healthy?"**
Claude calls `local_read_latency` / `local_write_latency` across all nodes. Show the
even distribution — and that the three newest nodes have lower counts because they
only just joined.

**Step 2 — Kill a node, live:**

> **Ask Claude:** _"Force-kill the pod `demo-dc1-rack2-sts-1` — no grace period, no
> graceful drain. I want it to die the way a real node dies."_

Ask for the force-kill explicitly. A polite `kubectl delete pod` gives Cassandra a clean
drain, which is a demo of a rolling restart, not of a node failure. The 44-second recovery
below is only impressive because nothing was handed over.

**Step 3 — "What do you see now?"**
Claude re-queries and surfaces the anomaly: surviving nodes in the hundreds of
thousands of ops, the restarted node at a fraction of that and ramping. It
interprets it as a recent restart, not a fault, and notes the load test never
dropped a query.

**MEASURED, 17 Sep rehearsal.** Force-killed `demo-dc1-rack2-sts-1` with
`--grace-period=0 --force` - no graceful drain, the way a node actually dies -
while 60,014 ops/sec were flowing:

| | |
|---|---|
| Node detected `DN` | ~24 s |
| Back to `UN` | **44 s** |
| Pod `3/3 Running` | **64 s** |
| Throughput | 60,267 -> 57,082 -> 59,373 (worst dip ~5%) |
| `unavailables` | **0** |
| `failures` | **0** |
| `timeouts` | **1**, over 10 minutes and ~36M operations |

> ⚠️ **The throughput figures in this table are from BEFORE 22 Sep**, i.e. from the
> dataset whose partitions held 1.4 rows. The **timings and the dip percentages are
> still good** — they are ring and streaming mechanics, not query mechanics — but do
> not quote the absolute ops/sec from here alongside the corrected numbers elsewhere.
> Tomorrow's run-through re-measures them.

Quote the 1, not "zero" - it is a more credible number and it is the truth.

**Two details worth showing, because they are the actual mechanism:**

- The node logged **`Using saved tokens`** and reused its PVC
  (`server-data-demo-dc1-rack2-sts-1`), keeping the same host ID. It did **not**
  re-bootstrap - there was no streaming, because the data was already on disk.
  Cassandra saw the same node returning from a brief outage, not a new one.
- NoSQLBench will print red `ConnectionInitException` warnings. **Those are not
  query failures.** They are the driver's admin thread rebuilding its connection
  pool against the replacement pod's new IP, backing off 8.7s -> 14.9s -> 21.9s
  -> 30.9s. Have that answer ready: point at `unavailables` and `timeouts` and
  say "no query failed; that is a pool reconnect."

**The point:** in the old world that was a maintenance window, a runbook, and a
Slack thread. Here it is a 64-second demo with a natural-language debrief.

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

**This is the strongest ~3 minutes in the talk — and after the 22 Sep rework it
mutates nothing on the cluster.** Three Grafana panels, one skill invocation, and a
decision. It is now the segment least likely to fail on camera.

Last run, `/diagnose` fanned out via `query_all_nodes` against `system_views.*` and
compared all 9 nodes. The headline find:

> Pods pegged at **6.0 / 6.0 CPU**, EC2 hosts at **30-70%**, and **zero pending
> thread-pool tasks**.

**Caveat on that 6.0 / 6.0.** It is exactly the same shape as the number corrected
below — a per-pod CPU figure that lands suspiciously precisely on its own limit —
and that EKS cluster no longer exists to re-measure. Its dashboard scraped the
kubelet through our own Prometheus rather than OpenShift's Thanos, so it probably
was not double-counted, but "probably" is the honest word. If you would rather not
defend it live, the throttling *conclusion* stands on the OpenShift numbers alone;
lead with those and treat the EKS run as the anecdote that started the hunt.

That is CFS throttling at the cgroup level — invisible to `nodetool tpstats`,
invisible to a flat dashboard. It accounted for the ~8k ops/sec gap between the
100k target and the ~92k achieved.

`/optimize` then tier-ranked the fixes. The Tier-1 surprise: the operator default
ships `key_cache_size_in_mb: 0`, while the table requests `caching: {keys: ALL}` —
the table-level setting is silently meaningless without the YAML setting.

**What this cluster does differently, because of that analysis:**

| Finding | Change in the repo |
|---|---|
| `key_cache_size_in_mb: 0` vs `caching: {keys: ALL}` | `key_cache_size: 200MiB` |
| 16 KiB compression chunks, ~250x I/O amp on point lookups | `chunk_length_in_kb: 4` |
| Soft anti-affinity that no-ops when every node has a Cassandra pod | Dedicated **tainted** loadgen node |
| CFS throttling at the cgroup ceiling | **Deliberately left in place — see below** |

### Two failures, and neither layer could see both

During rehearsal this cluster produced a second failure that pairs with the first
almost too neatly.

**Failure 1 — Cassandra cannot see its own ceiling.** Measured **22 Sep**, ring size 3,
under the 60k load, on the corrected dataset:

| | Measured | |
|---|---|---|
| Cassandra container CPU | **9.7 – 13.7 cores** | of a **14** limit |
| Utilisation of quota | **69 – 98 %** | |
| CFS periods throttled | **27 – 88 %** | |
| Worker node CPU | **~20 %** | the host is bored |
| p99 read / write | 39 ms / 20 ms | |
| Client-visible errors | **0** | |

`nodetool tpstats` is clean, thread-pool queues are shallow, and NoSQLBench reports
zero timeouts, unavailables or failures. From inside Cassandra **nothing is wrong** —
the ceiling is a cgroup quota, visible only in cAdvisor, via a *second* Grafana
datasource pointed at OpenShift's Thanos.

**That is the whole point in one row of the table.** The pod is being held down 88% of
the time while the worker it sits on is 80% idle, and every signal Cassandra exposes
says healthy. No amount of `nodetool` gets you there.

**What fixing it would buy, measured not guessed** (limit raised to 24, then reverted):

| | limit 14 | limit 24 |
|---|---|---|
| CFS periods throttled | 77 – 96 % | **0.2 – 0.3 %** |
| p99 read | 26.8 ms | **15.5 ms** |
| p99 write | 20.0 ms | **8.2 ms** |

Throttling essentially vanishes and p99 read halves. **This is evidence, not a demo** —
see the note under "Run it live" for why it is no longer performed on stage.

> **Correction, 21 Sep.** This table previously read 11.9 – 14.6 cores against a
> limit of 14 — i.e. pods pegged at the ceiling. That number was wrong, and the
> giveaway was on the same slide: a single pod burning 14.6 of a worker's 32 cores
> is 46%, not the 20–32% the node panel reported. The cause was the dashboard, not
> the cluster. OpenShift's Thanos returns **two identical cAdvisor series per
> container** (undeduplicated Prometheus replicas), and the panel used
> `sum by (pod)`, which double-counted every value. The CPU and memory panels are
> now `avg by (pod)`; the CFS throttling panel was always a `sum/sum` ratio, so the
> duplication cancelled and that number was never affected. Verified three ways:
> `kubectl top`, the container's own `/sys/fs/cgroup/cpu.stat`, and `avg by (pod)`
> all agree.
>
> Worth 30 seconds on stage if you want it: the observability layer was itself the
> thing lying, and it took a third source to catch it. That is the same lesson as
> the rest of Part 8, one level up.
>
> **Second correction, 22 Sep — and this one is more uncomfortable.** The numbers above
> were then measured *again* and moved *again*, because the dataset underneath them was
> wrong. The NoSQLBench workload used `AddHashRange` where it needed `HashRange`, which
> ADDS the cycle instead of bounding it. Over 50M cycles that produced timestamps in
> the year 22,384 and **35.5 million partitions averaging 1.4 rows each** — so every
> "range scan" in the read workload was really a point read, and the cluster was barely
> working. With the data model fixed (588k partitions, ~83 rows each) the same cluster
> is CPU-pegged at 69–98% of quota.
>
> So: the 21 Sep correction was right about the dashboard and right for the data that
> existed then. The data changed. **If you tell the dashboard story on stage, tell this
> half too** — "I corrected the number, then the number moved again when I fixed the
> thing generating it" is a better and more honest arc than a single clean catch.

**Failure 2 — Kubernetes cannot see a dead node.** The disks filled. Two of three
nodes shut down. And:

```
$ kubectl get pods -l app.kubernetes.io/name=cassandra
demo-dc1-rack1-sts-0   3/3   Running
demo-dc1-rack2-sts-0   3/3   Running     <-- dead
demo-dc1-rack3-sts-0   3/3   Running     <-- dead

$ nodetool status
UN  10.129.2.173  rack1
DN  10.131.0.91   rack2
DN  10.131.2.31   rack3
```

`commit_failure_policy: stop` halts CQL and gossip **but leaves the JVM running**.
The container never exits, the pod never restarts, every Kubernetes signal says
healthy. The node is simply gone from the ring.

**That is the whole argument in one slide.** One failure invisible to Cassandra,
one invisible to Kubernetes, each only diagnosable from the layer the other cannot
reach. Neither `nodetool` alone nor `kubectl` alone gets you there.

### Run it live

1. Grafana **"CFS throttling (% of periods)"** — and it is not subtle.
2. **"Worker node CPU utilisation"** — twenty-something percent. The host is bored.
3. Cassandra's **thread pool pending tasks** — shallow. Nothing is queuing.
4. Ask Claude `/diagnose`. Three signals that each look fine alone and only mean
   something together, which is exactly the reasoning a skill encodes.

Then put `kubectl get pods` beside `nodetool status` from the rehearsal
screenshots. The two-layer point lands in about fifteen seconds.

**Then land it as a decision, not a fix:**

> _"The skill is telling me I'm leaving throughput on the floor. I know. That limit is
> sized for two pods per worker after the scale-up, and I'd rather show you a
> constrained cluster honestly than a tuned one. I measured what fixing it buys —
> throttling goes to 0.3%, p99 read halves — and I'm choosing not to."_

> **Why there is no "raise the limit live" step any more (removed 22 Sep).**
> There used to be a step 5 that raised the CPU limit on stage. It is gone, for three
> reasons, and the timing one is the least important:
>
> 1. **It contradicted this very segment.** The table above says the throttling is
>    *"deliberately left in place"*, and the closing quote says *"I'm choosing to live
>    with two."* Spending three minutes justifying a constraint and then undoing it on
>    camera cannot be the point.
> 2. **It is off-thesis.** This talk is k8ssandra, MCP and skills. Tuning a Kubernetes
>    CPU limit is none of those. The *diagnosis* is on-thesis — correlating three
>    signals no single layer exposes. The remediation is ordinary ops work that needs
>    no agent, and showing it invites "so this is a resource-limits talk?"
> 3. **Part 8 already has its action half** — five concrete repo changes came out of
>    these skills. It does not need a sixth, performed live.
>
> Also, it could not have worked: a CR edit triggers a rolling restart, **measured at
> 9.1–9.7 minutes** at ring size 3 across three separate runs on 22 Sep. Part 8 is
> eight minutes. You would have started it and run out of talk.
>
> Keeping the *measurement* and dropping the *action* makes the point stronger, not
> weaker: a tool whose advice you can knowingly decline is more credible than one you
> always obey.

### What got fixed because of it

| Finding | Change |
|---|---|
| `commit_failure_policy: stop` hides a dead node on Kubernetes | **`die`** — the JVM exits, the container terminates, a persistent failure surfaces as CrashLoopBackOff |
| `commitlog_sync_period: 10000ms` on network-attached storage | **2000ms** — the 10s default is for spinning disks |
| PVCs sized from dataset size | **150Gi**, sized for write throughput x duration |
| Nothing warned before the disk filled | Grafana panels 11-13, including **projected hours until full** |

Both config fixes came out of the `cassandra-expert` references rather than from
guessing — which is the point. The skill already knew `die` was correct for a
supervised process; it took a live outage to make me go and look.

**Be straight about the constraint.** The 14-core limit is sized for two pods per
worker after the scale-up. At ring size 3 each pod has a whole ~31.5-core worker to
itself, so the quota binds a pod that could otherwise spread out — and it measurably
does: **27–88% of CFS periods throttled while the worker sits ~80% idle.** Every
throughput number from this cluster comes from a deliberately constrained one, and it
costs roughly **13% of target throughput** (52.5k sustained against a 60k ask). Say so
plainly; it is more interesting than a number with no story behind it.

**And `softPodAntiAffinity` is still on**, because three workers cannot host a
six-node ring any other way. `/expert` calls it "defensible only for
dev/CI/workshop, not for any RF=3 cluster where availability matters." It is right.

That is a better ending than a clean sweep. A tool that tells you something
inconvenient, which you then accept with your eyes open, is more useful than one
that only confirms what you already did.

> _"The operator defaults shipped five production tunings missed. The loop surfaced
> all of them in under an hour. I fixed three, and I'm choosing to live with two —
> and I can tell you exactly why for each one."_

**Check Reaper here** — the repair from Part 5b should have made real progress.
At ~2 segments/min, roughly 25–30 minutes after you started it, expect **12–15%**
(~55–65 of 436 segments). Say the percentage out loud rather than implying it is
nearly done: a repair that is 13% through after half an hour is the honest picture,
and it is why the thing runs unattended.

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
     And check whether one already exists — Grafana ships its own, and it found a bug
     in this deck.
  2. Turn your runbooks into skills. If you wrote it down, Claude can follow it.
  3. Combine both: MCP for observation, skills for action. Then **verify across
     layers** — the dashboard was the thing lying, and only a second source caught it.
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
| T-180 | Ask Claude: _"Show the worker nodes with their workload and rack labels and any taints — I need 3 Cassandra workers across 3 racks plus a tainted loadgen node."_ **Hard gate.** |
| T-178 | `./manifests/openshift/node-labels.sh` then `./scripts/deploy-openshift.sh` — these two stay as scripts. They are the deploy, not a demo |
| T-148 | Ask Claude: _"Check the ring: one pod per rack, all UN. Is there a ServiceMonitor? Is the Grafana Route serving?"_ |
| T-143 | **Restart Claude Code first**, then verify BOTH servers: _"Query all nodes for their release version"_ (easy-cass-mcp) and _"List the Grafana datasources"_ (grafana). See the MCP restart note below — this step catches a failure that is otherwise invisible until you are on camera |
| T-135 | `nosqlbench-payments-prepare-job` — schema + 50M-row load |
| T-117 | **Pre-flight Medusa backup** to prove the MinIO path end to end, then delete it so the live one is a genuine first full backup. Use a DIFFERENT name for the live one — Medusa keeps backup metadata in the bucket, so a reused name fails with "already exists" even after the Kubernetes object is deleted |
| T-109 | **Pre-flight Reaper repair** to ~20%, then abort — proves registration and `reaper_db` migration |
| T-103 | Start the main NoSQLBench job |
| T-100 → T-40 | **Soak.** Throughput settles, driver pool warms, Grafana accumulates history. Touch nothing. |
| T-40 | Confirm sustained ops/sec. If it's short of target, lower `cyclerate` now rather than demoing a miss |
| T-25 | Open all three Routes in tabs and confirm they load **and that you are logged in** (see Live endpoints above): Grafana, Reaper, and the MCP `/mcp/` endpoint. No port-forwards to babysit on OpenShift — that is one fewer thing to fail live |
| T-20 | Screenshot every live moment as a backup slide; Zoom share test at presentation font size |

> **The MCP restart trap — this bites every redeploy.**
> `deploy-openshift.sh` rewrites `.mcp.json` and mints a **new** Grafana
> service-account token on every run. It has to: the kube-prometheus-stack chart
> gives Grafana an `emptyDir` for its database, so service accounts do not survive
> the pod restart the script itself performs.
>
> `mcp-grafana` reads that token **once at startup, not per request.** So an
> already-running Claude Code session keeps presenting the old token and gets
> `401 Unauthorized` on every call — while `curl` with the new token works fine.
> Verified on 21 Sep: valid token, dead server, no error anywhere except the tool
> call itself.
>
> **Restart Claude Code after every deploy, then check both servers.** That is what
> T-143 is for.

**The pre-warm rule:** anything that can fail *silently* (Medusa credentials, Reaper
schema migration, ServiceMonitor discovery, MCP connectivity) gets proven before the
audience arrives. Anything whose *duration is the point* (the backup upload, the
repair progress bar, the 3→6 bootstrap) is done live. The backup and the repair each
run twice — once quietly to prove the plumbing, once on camera.

**Numbers marked «MEASURE AT REHEARSAL» must be filled in before the talk.** Do not
quote the old run's figures for the new cluster — it has different CPU limits,
different anti-affinity, and three racks.

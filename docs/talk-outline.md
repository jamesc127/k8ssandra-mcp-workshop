# Control C* Con Claude Code: k8ssandra, MCP, and Skills

**Event:** [Planet Cassandra #18](https://luma.com/1osqeg4d) — Zoom webcast, **Wed 23 Sep, 12:00 Central**
**Format:** 60-minute talk + live demo, ~10 min Q&A
**Repo:** k8ssandra-workshop
**Companion repos:**
- MCP server: [rustyrazorblade/easy-cass-mcp](https://github.com/rustyrazorblade/easy-cass-mcp)
- Skills: [rustyrazorblade/skills](https://github.com/rustyrazorblade/skills)

**Style:** Heavy live demo — Claude Code open on screen from Beat 1 onward.

> **Presenting from this? Don't.** `docs/talk-track.md` is the run sheet — the clock,
> the measured durations, what to say while each beat runs, and the failure playbook.
> This document is the design: why each segment exists and what was measured to get
> there. Keep the track on your second screen; read this one beforehand.
>
> **This outline follows the track's structure** — same section names, same clock
> (reconciled 22 Sep). If the two ever disagree again, **the track wins.**

> **Everything in the demos is driven from Claude Code in natural language.** There is
> no terminal typing in this talk. Claude is connected to two things at once: the
> **OpenShift cluster** (kubectl/oc, for pods, nodes, CRDs, scaling, killing things) and
> the **easy-cass-mcp server** (for anything Cassandra-internal — `nodetool`-equivalents,
> `system_views.*`, schema). Every quoted prompt below is **the prompt to type**, not the
> command to run.
>
> Three presenter notes about working this way live:
> - **Say what you asked for out loud** before you hit enter. The audience reads the
>   prompt; you narrate the intent.
> - **Let them watch the tool calls.** The interesting part is often *which* tool Claude
>   reaches for — MCP for ring state, kubectl for pod state. That split is Beat 4's whole
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

All four are OpenShift Routes with **edge TLS**, so they are real `https://` — no
port-forward, no `--allow-http`, nothing to babysit. Have them open in tabs and
logged in before you go live.

| What | URL |
|---|---|
| **Grafana** | https://grafana-monitoring.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com |
| **Reaper** | https://reaper-default.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com/webui/ |
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
> matters, and how it fits into modern Cassandra operations."* The k8ssandra explainer
> gets **14 minutes**, and the two demos that bracket it — the backup before it, the
> scale after the diagnosis — are k8ssandra doing its job live. That is **28 minutes,
> nearly half the talk**, on exactly what was promised. MCP and skills get the rest,
> and stop being the whole talk.

## Time budget

| Clock | Section | Min | |
|---|---|---:|---|
| 0:00 | Cold open — the cluster is already under load | 3 | |
| 3:00 | **Beat 1 — Backup** | 6 | ▶ start it first |
| 9:00 | The journey — hand-YAML → operators → k8ssandra | 5 | |
| 14:00 | **★ What k8ssandra is** | 14 | the segment this was sold on |
| 28:00 | **Beat 2 — Skills** | 8 | diagnose the 3-node ring — mutates nothing |
| 36:00 | **Beat 3 — Scale 3 → 6** | 8 | ▶ start it, then talk |
| 44:00 | **Beat 4 — MCP** | 6 | ⏸ the scale lands here |
| 50:00 | **Beat 5 — Kill a node** | 6 | ▶ force-kill |
| 56:00 | Close | 4 | |
| 60:00 | Q&A | ~10 | |

### Five demos, and nothing else

Backup, skills, scale, MCP, node kill — against a load test that is simply always
there. Everything else that used to be a live segment was cut on 22 Sep:

- **Reaper is not a beat.** A repair is optional, and never before the scale-up: if
  one runs at all, it is started from the Reaper tab once the ring is 6/6 UN, late in
  Beat 4. It earns exactly one line, in Beat 5: _"the repair didn't even notice."_
- **Monitoring / ServiceMonitor is not a demo.** It is folded into the k8ssandra
  section as "four lines of `telemetry:` produced all of this", shown on Grafana.
- **The CRD map is a slide**, not a live query.

That is what buys the k8ssandra explainer 14 minutes instead of 12.

**Why this order (reordered 23 Sep).** Backup is ~4–5 min at size 3 but **8m38s at
size 6** — so it goes straight after the cold open, while the ring is small and before
anything else can touch it. Skills comes *before* the scale because the diagnosis only
exists at size 3: CFS throttling is 27–88% there and 0.2–2% at size 6, so `/diagnose`
after the scale would find nothing to explain. Diagnose the gap the cold open named,
then close it — the diagnosis is what motivates the scale. The scale takes 9m20s and
spans into the MCP beat, so MCP's first job is confirming the ring landed, which turns
dead air into content. You cannot force-kill a node mid-bootstrap, so the kill waits
until 6/6 UN.

One consequence: **the audience sees MCP work in Beat 2 before Beat 4 explains it.**
`/diagnose` calls easy-cass-mcp on screen. Let it — Beat 4 opens by naming what they
already watched.

**Pre-show state (see README step 6 and the runbook at the end):** ring at **`size: 3`**
— Beat 3 scales it to 6 live, so it must start at 3 — dataset preloaded, NoSQLBench
running for ~60 min so throughput has settled, Reaper registered but **no repair
running**, Grafana and Reaper tabs open and logged in, Claude Code restarted and both MCP servers
verified.

---

## Cold open (0:00, ~3 min) — The Cluster Is Already Under Load

Open on Claude Code, not a slide.

> **Ask Claude:** _"Show me every pod in the default namespace, with the node each one
> landed on."_

Point at what is on screen, in this order:
- **3 Cassandra pods**, named `demo-dc1-rack1-sts-0`, `rack2`, `rack3` — three racks
- A **medusa sidecar inside every Cassandra pod** — Beat 1 points back at this
- A **Reaper** pod
- **easy-cass-mcp**
- Over in `monitoring`: **Prometheus and Grafana**

(The node-labels query that used to follow is gone. The "racks are just a label on
a node" point lands better in Beat 3, where it is the reason the scale works.)

Then switch to the Grafana tab, already showing an hour of history at
**~52,500 ops/sec against a 60,000 ask** (measured 22 Sep: 44,648 read + 7,879 write,
an 85/15 mix, zero errors).

> _"Everything you're about to see is live. It's been running for an hour, it's
> under load right now, and I'm not going to stop it for the rest of the talk."_

🎯 **Name the gap here. It is deliberate, and it is the setup for Beats 2 and 3.**

> _"We're asking this cluster for sixty thousand operations a second and it's giving me
> about fifty-two and a half. Nothing is failing — zero errors, zero timeouts. It just
> can't go any faster. Hold that number."_

**Decided 22 Sep: `cyclerate` stays at 60000.** The cluster sustains ~52.5k because it
is CPU-bound against its 14-core limit, so the graph sits ~13% under its own target.
**That gap is the point, not a blemish.** Beat 2 explains why it is there when
`/diagnose` finds the cgroup ceiling; Beat 3 closes it by doubling the ring.

A flat line that meets a lowered target demos nothing. A shortfall you diagnose and
then fix with capacity is the whole talk in one number.

---

## Beat 1 — Backup (3:00, ~6 min) — ▶ START IT BEFORE YOU EXPLAIN IT

> **Ask Claude:** _"Start a full Medusa backup from
> `manifests/cassandra/medusa-backup-job.yaml`, then watch the job and tell me as each
> node finishes."_

**Timing, measured 21 Sep:** a full backup of a loaded **6-node** ring took
**8 min 38 s** — 47.84 GB across 4,732 files. At **size 3**, expect roughly
**4–5 minutes**. That fits the beat, but only just: start it *first*, then talk. Do
not start it after the explanation.

Talk while it uploads:
- **The S3 endpoint is in-cluster.** MinIO, on a Ceph RBD volume, in the same
  namespace as Cassandra. No AWS account, no IAM request, no ticket to a cloud team.
  Medusa just sees an S3 endpoint.
- Medusa is configured `s3_compatible` rather than `s3`, with an explicit host
  instead of an AWS region. **That is the portability, and it is load-bearing rather
  than decorative** — the same five lines point at MinIO, AWS S3, GCS or anything else
  that speaks the API. It is the reason this workshop can run on a cluster with no
  cloud account attached to it at all.
- `backupType: full` so every sstable re-uploads and you can actually watch it
- The work is done by the **medusa container inside every Cassandra pod** — point back
  at the cold open. Backup is not a separate system to operate

Then the payoff:

> **Ask Claude:** _"Show me the finished MedusaBackup objects with per-node sizes."_

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

## The journey (9:00, ~5 min) — Hand-YAML → Operators → k8ssandra

Three old sections compressed into one. **Keep it tight — it is setup for the
k8ssandra section, not a destination.**

**The consultant (~1 min)**
- Speaker intro: background as a Cassandra consultant
- Thesis: AI tooling is changing how we operate databases — but there are multiple
  approaches with real tradeoffs
- _"By the end of this talk I'm going to double the size of this cluster and kill a
  node, in front of you, while a load test is running — and then ask Claude what
  happened."_

**Hand-editing YAML: the dark ages (~2 min)**
- `cassandra.yaml`, `cassandra-env.sh`, `jvm.options` — across N nodes, by hand
- Seed lists, rack assignments, snitch configs, GC tuning — all bespoke per cluster
- Config drift is the real enemy: one wrong indent and a node won't join the ring
- Rolling restarts: SSH into each node in order, pray nothing times out, repeat
- _"I've seen more YAML than my family"_

**Cassandra meets Kubernetes: hope and pain (~2 min)**
- **The promise:** declarative infrastructure, self-healing, automated scaling
- **The hardest problems:** PVCs that don't follow pods; rolling restarts that know
  nothing about streaming or repair state; rack-aware scheduling, anti-affinity and
  token math, all by hand
- **Config management only got you halfway.** Ansible, Terraform and Puppet get you
  to a desired state; they don't *keep* you there. A dead node is still a dead node
  waiting for a human and a playbook run.
- **The gap:** you can automate the deploy and still have nothing that runs repairs,
  takes backups, or tells you the cluster is unhealthy.

---

## ★ What k8ssandra is (14:00, ~14 min)

**This is the segment the event was sold on.** Deck slides 3–10.

### a. What k8ssandra is, and isn't (~2 min)

- An **umbrella project**, not a single operator
- **Not** a fork of Cassandra. **Not** a distribution. It runs stock Apache
  Cassandra — the exact 5.0.8 you'd download — with operators around it
- Lineage: born out of the DataStax Kubernetes work, now a community project; the
  same engineering that underpins Mission Control

**Stargate — name it, and be straight about it.** It was the project's data-API
gateway (REST, GraphQL, gRPC over Cassandra). It is **deprecated, and it does not
work with Cassandra 5.0+**. The operator emits a deprecation warning if you set the
field. It is not deployed in this workshop.

> _"I could have quietly left that off the slide. But a project that retires
> something and tells you clearly is a project you can plan around."_

### b. The components (~3 min)

Six pieces — three foundation, three batteries:

| Component | What it does |
|---|---|
| **cass-operator** | Owns the ring: StatefulSets, seed discovery, rack placement, rolling restarts that understand Cassandra's state |
| **k8ssandra-operator** | Owns the *suite*: reconciles one `K8ssandraCluster` CR into cass-operator resources plus everything below |
| **management-api** | Runs inside every Cassandra container — the HTTP control plane the operators actually drive (this is what replaced shelling into `nodetool`) |
| **Reaper** | Segmented, scheduled anti-entropy repair — the zombie-data preventer |
| **Medusa** | Backup and restore, a sidecar per pod, to any S3-compatible bucket |
| **metrics agent** | Native Prometheus endpoint via the management API, no JMX exporter to hand-roll |

There is also a **client CLI** for the bits that don't belong in a CR — worth a
mention, not a row.

Reaper gets its sentence here and nowhere else until Beat 5: *"it registered itself
— I configured nothing."*

### c. The CRD map — a slide (~2 min)

Show §4 of `docs/architecture-diagrams-openshift.md` (the CRD ownership map), with §2
for the workload layout if there are questions.

Point out the CRD *groups* — `k8ssandra.io`, `cassandra.datastax.com`,
`medusa.k8ssandra.io`, `reaper.k8ssandra.io`, `control.k8ssandra.io` — and that every
one of them is **instantiated** in this cluster, not just installed. "Installed" and
"instantiated" are different claims; this is the slide where you can make both.

**Why this is a slide and not a live query (decided 22 Sep):** a live call costs a
minute and a failure mode to make a point a static diagram makes just as well — and
the demos around this section already show Claude reading the cluster, five times.

### d. One CR, one suite (~2 min)

Put the CR on screen next to what it replaces:

- **One `K8ssandraCluster` CR — ~130 lines of YAML, 333 with the comments** →
  StatefulSets, headless services, the superuser secret, PVC lifecycle, rack
  placement, a repair scheduler, a backup pipeline, and ServiceMonitors
- The rack block is six lines. That's the token math from the journey, gone
- The ceiling: control-plane / data-plane split gives you multi-DC and
  multi-cluster from the same CR shape

### e. Monitoring — four lines of telemetry (~3 min)

**Shown on Grafana, not demoed.** Put the four lines of `telemetry:` from the CR on
screen, then switch to the
[Grafana tab](https://grafana-monitoring.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com):

> _"Those four lines produced all of this."_

Throughput, p99 read and write latency, pending compactions, per-pod CPU, disk used
per pod. The operator wrote the ServiceMonitor; there is no JMX exporter sidecar, no
scrape config, no relabeling rules.

- **Gotcha worth 20 seconds:** every published k8ssandra Grafana dashboard targets
  the deprecated MCAC endpoint (`collectd_mcac_*`). Cassandra 5 exposes
  `org_apache_cassandra_metrics_*` through the management API. Grab a community
  dashboard and every panel renders empty. This one was built against the live names.

### f. Governance and cadence (~2 min)

- **v1.33.0 released 2026-09-03** — shipping Reaper 5.0.1, Medusa 0.30.1,
  cass-operator 1.32.0
- Its entire changeset that release was Medusa and Reaper fixes — the component
  you just watched back up this ring, and the one that registered itself with no configuration. That's what an
  actively maintained project looks like
- Pin your versions. This workshop pins all four Helm charts, and the reason is
  boring and important: an unpinned chart that bumps between rehearsal and showtime

---

## Beat 2 — Skills (28:00, ~8 min) — 🚫 NOTHING IS MUTATED HERE

Three panels, one skill, one decision. **The segment least likely to fail on camera.**

### Run it live

1. Grafana **"CFS throttling (% of periods)"** — and it is not subtle
2. **"Worker node CPU utilisation"** — ~20%. The host is bored
3. Cassandra's **thread pool pending tasks** — shallow. Nothing is queuing
4. Ask Claude `/diagnose`. Three signals that each look fine alone and only mean
   something together, which is exactly the reasoning a skill encodes

**This is the audience's first look at MCP.** `/diagnose` fans out through easy-cass-mcp
(`query_all_nodes` against `system_views.*`). Let them watch the tool calls and don't
stop to explain the protocol — Beat 4 names what they saw.

Then put `kubectl get pods` beside `nodetool status` from the rehearsal screenshots
(Failure 2 below). The two-layer point lands in about fifteen seconds.

**Land it as a decision, and make the decision the bridge into Beat 3:**

> _"The skill is telling me I'm leaving throughput on the floor. It's right. I measured
> what raising the limit buys — throttling goes to 0.3%, p99 read halves — and I'm not
> doing it. That limit is sized for two pods per worker, which is exactly what we're
> about to have. So instead of giving three pods more CPU, I'm going to give this
> cluster three more pods."_

⛔ **Do NOT raise the CPU limit live.** See "Why there is no raise-the-limit step" below.

### What a skill is

A markdown file with trigger conditions and instructions, loaded into Claude Code's
context on demand. No running service, no deployment.

| | MCP Server | Claude Code Skill |
|---|---|---|
| **What it is** | Running service exposing tools via protocol | Markdown file with instructions |
| **Where it runs** | Separate process or container | Loaded into the agent's context window |
| **What it provides** | Live data access (query, mutate) | Domain knowledge and procedures |
| **Context cost** | Each tool call's results fill the window | Loaded once when triggered |
| **Maintenance** | Write code, deploy, monitor a service | Edit a markdown file |
| **Best for** | Real-time data, actions with side effects | Runbooks, deployment playbooks, troubleshooting |
| **Limitation** | Generic servers bloat context; needs infra | No live data access; static knowledge only |

**Together:** MCP is the data plane (what's happening right now); skills are the
control plane (what to do about it). The skill tells Claude *how*; MCP lets Claude
*verify*.

### Three Cassandra skills, three lenses ([rustyrazorblade/skills](https://github.com/rustyrazorblade/skills))

| | Lens | Output style |
|---|---|---|
| `/diagnose` | USE method (Utilization / Saturation / Errors) across all nodes | "Here's what's wrong (or right) and why" |
| `/optimize` | Tier-ranked tuning: `cassandra.yaml` + `ALTER TABLE` deltas | "Apply these in order, expected impact: X" |
| `/expert` | Opinionated big-picture — anti-patterns, trade-offs, production-readiness | "Here's what I'd actually do, and why" |

Only `/diagnose` runs live. The other two appear through what they found last time.

These aren't generic "ask an LLM" wrappers. They apply USE-method diagnostics,
published Cassandra-community stances on `num_tokens` and compaction, and
version-specific C* 5 features (UCS, Trie memtables, BTI, Zero-Copy Streaming) —
codified once, applied every time.

### The callback — what the skills found last time, and what we did about it

Last run (on EKS), `/diagnose` fanned out via `query_all_nodes` against
`system_views.*` and compared all 9 nodes. The headline find:

> Pods pegged at **6.0 / 6.0 CPU**, EC2 hosts at **30-70%**, and **zero pending
> thread-pool tasks**.

**Caveat on that 6.0 / 6.0.** It is exactly the same shape as the number corrected
below — a per-pod CPU figure that lands suspiciously precisely on its own limit —
and that EKS cluster no longer exists to re-measure. Its dashboard scraped the
kubelet through our own Prometheus rather than OpenShift's Thanos, so it probably
was not double-counted, but "probably" is the honest word. The throttling
*conclusion* stands on the OpenShift numbers alone; lead with those and treat the EKS
run as the anecdote that started the hunt.

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

**The whole argument in one sentence:** the pod is held down 88% of the time while the
worker it sits on is 80% idle, and every signal Cassandra exposes says healthy. No
amount of `nodetool` gets you there.

**What fixing it would buy, measured not guessed** (limit raised to 24, then reverted):

| | limit 14 | limit 24 |
|---|---|---|
| CFS periods throttled | 77 – 96 % | **0.2 – 0.3 %** |
| p99 read | 26.8 ms | **15.5 ms** |
| p99 write | 20.0 ms | **8.2 ms** |

Throttling essentially vanishes and p99 read halves. **This is evidence, not a demo.**

> **The number moved twice, and both corrections are worth knowing.**
>
> **21 Sep — the dashboard was lying.** This table once read 11.9 – 14.6 cores against
> a limit of 14. The giveaway was on the same slide: a single pod burning 14.6 of a
> worker's 32 cores is 46%, not the 20–32% the node panel reported. OpenShift's Thanos
> returns **two identical cAdvisor series per container** (undeduplicated Prometheus
> replicas), and the panel used `sum by (pod)`, double-counting every value. The CPU
> and memory panels are now `avg by (pod)`; the CFS throttling panel was always a
> `sum/sum` ratio, so the duplication cancelled there. Verified three ways:
> `kubectl top`, the container's own `/sys/fs/cgroup/cpu.stat`, and `avg by (pod)`.
>
> **22 Sep — the data was wrong.** The NoSQLBench workload used `AddHashRange` where it
> needed `HashRange`, which ADDS the cycle instead of bounding it. Over 50M cycles that
> produced timestamps in the year 22,384 and **35.5 million partitions averaging 1.4
> rows each** — every "range scan" was really a point read, and the cluster was barely
> working. With the data model fixed (588k partitions, ~83 rows each) the same cluster
> is CPU-bound at 69–98% of quota.
>
> **If you tell the dashboard story on stage, tell both halves** — "I corrected the
> number, then the number moved again when I fixed the thing generating it" is a better
> and more honest arc than a single clean catch.

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

**That is the whole argument in one slide.** One failure invisible to Cassandra, one
invisible to Kubernetes, each only diagnosable from the layer the other cannot reach.
Neither `nodetool` alone nor `kubectl` alone gets you there.

### Why there is no raise-the-limit step (removed 22 Sep)

There used to be a step that raised the CPU limit on stage. It is gone:

1. **It contradicted this segment.** Spending three minutes justifying a constraint
   as deliberate and then undoing it on camera cannot be the point.
2. **It is off-thesis.** The *diagnosis* is on-thesis — correlating three signals no
   single layer exposes. The remediation is ordinary ops work that needs no agent, and
   showing it invites "so this is a resource-limits talk?"
3. **It could not have worked.** A CR edit triggers a rolling restart, **measured at
   9.1–9.7 minutes** at size 3 across three runs on 22 Sep. The beat is eight minutes.
4. **There is a better remedy one beat away.** The limit is sized for six pods on three
   workers. The scale-up is the fix the limit was designed for.

Keeping the *measurement* and dropping the *action* makes the point stronger: a tool
whose advice you can knowingly decline is more credible than one you always obey.

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
itself, so the quota binds a pod that could otherwise spread out — **27–88% of CFS
periods throttled while the worker sits ~80% idle.** It costs roughly **13% of target
throughput** (52.5k sustained against a 60k ask) — which is the gap Beat 3 closes, next.

**And `softPodAntiAffinity` is still on**, because three workers cannot host a
six-node ring any other way. `/expert` calls it "defensible only for
dev/CI/workshop, not for any RF=3 cluster where availability matters." It is right.

That is a better outcome than a clean sweep. A tool that tells you something
inconvenient, which you then accept with your eyes open, is more useful than one
that only confirms what you already did.

> _"The operator defaults shipped five production tunings missed. The loop surfaced
> all of them in under an hour. I fixed three, and I'm choosing to live with two —
> and I can tell you exactly why for each one."_

---

## Beat 3 — Scale 3 → 6 (36:00, ~8 min) — ▶ START IT, THEN TALK

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
> node is joining, and whether throughput dipped."_

**Start it, then talk over it** — bootstraps are serial and this takes **9 min 20 s**.
The beat is 8 minutes, so the scale lands at about **45:20, inside Beat 4**. That is
intentional: Beat 4 opens by asking whether it landed. But it means **do not
force-kill a node until the ring is 6/6 UN** — that is Beat 5's gate.

### The payoff: the gap from the cold open closes

You opened saying the cluster wanted 60k and gave 52.5k. Doubling the ring is the
answer to exactly that. They have been looking at the shortfall since the cold open,
and Beat 2 just showed them the cause.
Call it as the last node joins:

> _"That's the number I asked you to hold. We were twelve percent short because three
> pods were pinned against a CPU limit. Same limit — twice the pods."_

✅ **Verified 22 Sep on the corrected dataset.** The gap does not just close — it
overshoots:

| | size 3 | size 6 |
|---|---|---|
| Throughput | 52,500 | **65,000+** |
| p99 read | 39 ms | **14.5 ms** |
| p99 write | 20 ms | **7.9 ms** |
| Container CPU | 9.7 – 13.7 of 14 | **6.3 – 8.9** |
| Throttled periods | **27 – 88%** | **0.2 – 2.0%** |
| Errors | 0 | **0** |
| Time to 6/6 UN | — | **9 min 04 s** |

**Narrate the overshoot — it is real and it looks great.** NoSQLBench has been running
~13% behind its 60k ask for an hour, so when capacity arrives it bursts to ~66k to
clear the backlog before settling back onto the 60k rate limit.

> _"It's not just hitting sixty thousand now — it's running ahead to make up what it
> couldn't do for the last hour. Watch it settle back onto the target."_

Be precise if asked: **60k is the rate limit, not the ceiling.** The overshoot is
catch-up. What was measured is that the ceiling is no longer below the ask.

### Material to fill the wait

- Each rack goes 1 → 2. `size` must be a multiple of 3 or the racks go unbalanced
- **Be straight about the compromise.** This cluster has three Cassandra workers, so
  doubling the ring means two replicas land on each node. For an RF=3 keyspace at
  LOCAL_QUORUM, losing one node now costs two of three replicas. You would not do
  this in production — and `/expert` says exactly that (callback to
  Beat 2). Say it out loud; the audience has three-node clusters too.
- **Racks don't have to be AZs.** This cluster has no zone labels at all, so the
  racks here are three worker nodes with a label I applied. A rack is a *logical*
  failure domain — map it to whatever your real one is. That reframing is the most
  portable idea in this section.
- **Rack-aware placement is the thing that failed last time** (optional, if there is
  time). Two racks, and Cassandra's default
  `allocate_tokens_for_local_replication_factor=3` couldn't allocate tokens —
  bootstrap just stalled. Worth telling as a failure, because it's the kind that looks
  like a hang, not an error.
- **Zero-Copy Streaming**: sstables stream at the file level, not row by row
- What the operator is doing: one node at a time, waiting for each to finish joining
  before starting the next — the thing you used to do by hand with a runbook and a
  Slack thread

### Mechanics, for your own understanding

**Timings, 17 Sep rehearsal:** patch to 6/6 `UN` in **9 min 20 s**, first new node
joined at ~2 min, **0** NoSQLBench errors. These are ring and streaming mechanics and
still hold. The throughput figures from that run were taken on the pre-22-Sep dataset
and have been removed, not footnoted.

**What ownership looks like mid-scale** — the shape Beat 4's ring query will probably
catch, since the scale is still running when you ask:

```
UN  rack1   original             owns 51.5%
UN  rack2   original             owns 51.5%
UN  rack3   original             owns 100.0%   <- not yet split
UN  rack2   NEW, joined          owns 48.5%
UJ  rack1   NEW, still streaming
```

One rack still at 100% while the others have already halved. That single screen says
more about what the operator is doing than any slide would.

**A caveat worth knowing.** On 17 Sep the scale succeeded and the load never saw an
error — but the `server-system-logger` sidecar OOMKilled on several pods during it
(128 MiB limit, 122 MiB steady state). Cassandra was untouched and never left the
ring, yet those pods reported **2/3 Ready**. The limit is now 256 MiB.

That is the exact inverse of the disk-full failure in Beat 2, where the pod said
3/3 Running and Cassandra was dead. Pod readiness was wrong in both directions, for
opposite reasons.

---

## Beat 4 — MCP (44:00, ~6 min) — ⏸ THE SCALE LANDS DURING THIS BEAT

Open with the question the audience is already asking:

> **Ask Claude:** _"Is the ring at 6 nodes yet? Give me each node's rack, load and
> ownership."_

**It will probably still be joining** — the scale started at 36:00 and needs 9m20s.
That is the better answer, not the worse one: you get a live `UJ` node and an
ownership split mid-flight, which is the most honest picture of what the operator is
doing. Ask again later in the beat and it will be 6/6.

That is MCP earning its place: the thing you started eight minutes ago, verified in one
sentence instead of a terminal full of `nodetool`. **Do not kill anything until it
says 6/6** — you have until 50:00.

**Optional, once it says 6/6:** start a full repair of `payments` from the Reaper tab
and leave it. It is only there to give Beat 5 its best line, and it needs a couple of
minutes of visibly ticking segments before the kill. Skip it and Beat 5 simply loses
one sentence.

### What MCP is, and why this one is narrow

- **Name what they already saw.** The tool calls `/diagnose` made in Beat 2 were MCP.
  This is the plumbing behind them.
- **MCP in 30 seconds** — Model Context Protocol, a standard for giving models tools.
  Server exposes tools → Claude calls them → results come back as context.
- **easy-cass-mcp:** a domain-specific MCP server that speaks CQL, deployed
  in-cluster. Claude Code → OpenShift Route (edge TLS) → easy-cass-mcp pod → Cassandra
  pods. The endpoint is
  `https://easy-cass-mcp-default.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com/mcp/`
  — worth putting on the slide, because "the MCP server is a URL your agent dials" is
  the whole architecture in one line.

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

- **It is not mine.** Everything else on stage is something I built or configured.
  This is a vendor arriving at the same pattern independently, which is the difference
  between "here is my clever setup" and "here is where the ecosystem is going."
- **It solves a real constraint.** Prometheus on this cluster is ClusterIP with no
  Route. The server proxies PromQL *through* Grafana's datasource API, so it needs
  only the Grafana URL and a token — nothing new exposed.
- **It spans both layers.** It can reach our kube-prometheus-stack *and* OpenShift's
  Thanos. That is Beat 2's two-layer argument with the agent as the thing that spans
  them, instead of you alt-tabbing between dashboards.

> **The story worth telling, because it is true and it is recent.** Within ten minutes
> of being connected, it caught a wrong number on this deck. Slide 17 claimed Cassandra
> was pegged at 14/14 CPU. It was not — OpenShift's Thanos returns two identical
> cAdvisor series per container, the panel summed them, and every CPU and memory reading
> was double. The tell was already on the slide: the worker-node panel disagreed, and
> had for days.
>
> _The AI made a claim I could check against two other sources, and checking is what
> found it._ That is the honest version of the whole talk — not "the AI was right".

---

## Beat 5 — Kill a node (50:00, ~6 min) — ▶ ONLY AFTER 6/6 UN

_The load test is still running. The ring just went to 6._

> **Ask Claude:** _"Force-kill the pod `demo-dc1-rack2-sts-1` — no grace period, no
> graceful drain. I want it to die the way a real node dies."_

**Ask for the force-kill explicitly.** A polite `kubectl delete pod` gives Cassandra a
clean drain, which is a demo of a rolling restart, not of a node failure. The
44-second recovery below is only impressive because nothing was handed over.

**Measured, 17 Sep rehearsal** — `--grace-period=0 --force` under the 60k load:

| | |
|---|---|
| Node detected `DN` | ~24 s |
| Back to `UN` | **44 s** |
| Pod `3/3 Running` | **64 s** |
| `unavailables` / `failures` | **0** / **0** |
| `timeouts` | **1**, over 10 minutes and ~36M operations |

**Quote the 1, not "zero".** It is a more credible number, and it is the truth. (The
throughput trace from that run was on the pre-22-Sep dataset and has been dropped; the
timings are ring mechanics and still hold.)

### 🌟 The line that lands: the repair didn't notice (only if you started one)

If you started a Reaper repair once the ring hit 6/6, it is running now — and **a
force-kill does not interrupt it.** Measured 21 Sep: segments kept incrementing
straight through (22 → 23 → 24), at the same ~2/min, and Reaper never restarted.

Why that matters, in two sentences if anyone asks: replicas drift because writes
fail, hints expire, and nodes miss mutations while down. If a deleted row isn't
repaired before `gc_grace_seconds`, the tombstone is collected and the row comes back
from a replica that never heard about the delete — zombie data.

And why the repair is never the demo itself: a full repair of
`payments` is **436 segments at ~2/min, and completed in 3 h 40 min** (measured on an
idle 6-node ring). **Do not apologise for that number — it is the entire argument for
Reaper.** A multi-hour job split into hundreds of resumable segments, paced so it does
not compete with production traffic, that survives a node dying underneath it, is
exactly the job you do not want to run by hand. If the bar were "finishes during a
conference talk", nobody would need the tool.

Two different events, two different outcomes, both measured 21 Sep:

| Event | Reaper | The repair |
|---|---|---|
| **Force-kill one node** — what this beat does | **no restart** | **never paused**, same ~2/min throughout |
| **Rolling restart of every pod** (any CR edit) | exits code 1 after 9 s, recovers on its own | resumes from the last completed segment |

**Why the repair waits until after the scale (decided 22 Sep).** Starting it at 6/6
reproduces the 21 Sep measurement exactly — repair started at size 6, node killed at
size 6, no topology change in between. A repair that spans the 3 → 6 scale-up was
never measured, so it is not attempted.

> ⚠️ **One combination is still unmeasured:** the kill timings above (17 Sep) were taken
> with no repair running, and the 21 Sep repair measurement was on an idle ring. A
> repair *plus* the 60k load *plus* the kill has not been run together. The repair
> adds load, so expect the recovery to be no faster than 44 s / 64 s. If the repair is
> not visibly ticking before 50:00, skip it and the line — the kill stands on its own
> numbers.

### Then the debrief

> **Ask Claude:** _"What do you see now?"_

Claude re-queries and surfaces the anomaly: the restarted node's counters are a
fraction of its peers' and ramping. It should read that as a recent restart, not a
fault, and note the load test never dropped a query.

**Two details worth showing, because they are the actual mechanism:**

- The node logged **`Using saved tokens`** and reused its PVC
  (`server-data-demo-dc1-rack2-sts-1`), keeping the same host ID. It did **not**
  re-bootstrap — there was no streaming, because the data was already on disk.
  Cassandra saw the same node returning from a brief outage, not a new one.
- NoSQLBench will print red `ConnectionInitException` warnings. **Those are not
  query failures.** They are the driver's admin thread rebuilding its connection
  pool against the replacement pod's new IP, backing off 8.7s → 14.9s → 21.9s
  → 30.9s. Point at `unavailables` and `timeouts`: _"no query failed; that's a pool
  reconnect."_

**The point:** in the old world that was a maintenance window, a runbook, and a
Slack thread. Here it is a 64-second demo with a natural-language debrief.

---

## Close (56:00, ~4 min) — The Stack of the Future

- **The full picture:**
  - **k8ssandra** manages the cluster — ring, repairs, backups, metrics
  - **MCP** gives AI live access to what it's actually doing
  - **Skills** give AI the knowledge to reason about what it sees
- **Three things to take home:**
  1. Build domain-specific MCP servers, not generic ones. Context windows are precious.
     And check whether one already exists — Grafana ships its own, and it found a bug
     in this deck.
  2. Turn your runbooks into skills. If you wrote it down, Claude can follow it.
  3. Combine both: MCP for observation, skills for reasoning. Then **verify across
     layers** — the dashboard was the thing lying, and only a second source caught it.
- _"The operator alone manages the cluster. The full loop *operates* it."_
- **Links:** workshop repo `ibm.biz/k8ssandra-claude-repo`,
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
| T-109 | **Confirm Reaper has registered `demo`** — that proves the `reaper_db` schema migration, the silent failure. **Do NOT start a repair.** If one runs at all, it starts after the scale-up, late in Beat 4 |
| T-103 | Start the main NoSQLBench job |
| T-100 → T-40 | **Soak.** Throughput settles, driver pool warms, Grafana accumulates history. Touch nothing. |
| T-40 | Confirm **~52.5k sustained against the 60k ask**, zero errors. **Do NOT lower `cyclerate`** — the shortfall is the setup for Beats 2 and 3 |
| T-25 | Open the Routes in tabs and confirm they load **and that you are logged in** (see Live endpoints above): Grafana, Reaper (`demo` listed, no repair running), and the MCP `/mcp/` endpoint |
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
audience arrives. Anything whose *duration is the point* (the backup upload, the 3→6
bootstrap) is done live. The backup runs twice — once quietly to prove the plumbing,
once on camera. The repair, if it runs at all, runs once — started after the scale-up, and
never shown as a demo.

**The numbers policy:** anything measured before **22 Sep** was taken on a dataset
averaging 1.4 rows per partition and is not comparable. Those throughput figures are
gone, not footnoted. Ring and streaming timings (scale, node kill, rolling restart)
are not query mechanics and still stand. The track's numbers card is the canonical
list.

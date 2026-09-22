# Talk Track — Control C* Con Claude Code

**Wed 23 Sep, 12:00 Central.** 60 min + ~10 min Q&A.

The run sheet. `docs/talk-outline.md` holds the reasoning; this holds the clock.
Every number here is **measured on this cluster**.

## Five demos, and nothing else

| # | Demo | Costs | Where |
|---|---|---|---|
| — | **Load test** — the backdrop, already running | 0 | visible throughout |
| 1 | **Backup**, live | ~4–5 min | 22:00 |
| 2 | **Scale 3 → 6**, live | **9 min 20 s** | 28:00 |
| 3 | **MCP** — eyes on the cluster | — | 36:00 |
| 4 | **Kill a node**, live | ~64 s | 42:00 |
| 5 | **Skills** — diagnose | — | 48:00 |

**Why this order.** Backup is ~4–5 min at size 3 but **8m38s at size 6** — do it before
you scale or it costs double. The scale takes 9m20s and spans into the MCP segment, so
MCP's first job is confirming the ring landed, which turns dead air into content. You
cannot force-kill a node mid-bootstrap, so the kill waits until 6/6 UN.

## Clock

| Clock | Part | Beat |
|---|---:|---|
| 0:00 | Cold open | cluster already under load |
| 3:00 | The journey | hand-YAML → operators → k8ssandra |
| 8:00 | **What k8ssandra is** | ★ the segment this was sold on |
| 22:00 | Backup | ▶ **START BACKUP** (first thing) |
| 28:00 | Scale | ▶ **START SCALE** — talk over it |
| 36:00 | MCP | ⏸ confirm 6/6 UN |
| 42:00 | Kill a node | ▶ **FORCE-KILL** |
| 48:00 | Skills | `/diagnose` — mutates nothing |
| 56:00 | Close | |
| 60:00 | Q&A | |

---

## Cold open (0:00)

> _"Show me every pod in the default namespace, with the node each one landed on."_

Point at: 3 Cassandra pods across 3 racks · a **medusa sidecar inside each one** ·
Reaper · easy-cass-mcp · Prometheus and Grafana in `monitoring`.

Grafana tab — **~52,500 ops/sec against a 60,000 ask**, an hour of history,
**zero errors**.

> _"Everything you're about to see is live. It's been running for an hour, it's under
> load right now, and I'm not going to stop it for the rest of the talk."_

🎯 **Name the gap here. It is deliberate, and it is the setup for Beat 2.**

> _"We're asking this cluster for sixty thousand operations a second and it's giving me
> about fifty-two and a half. Nothing is failing — zero errors, zero timeouts. It just
> can't go any faster. Hold that number."_

`cyclerate` stays at **60000** on purpose. A flat line that meets a lowered target
demos nothing. A visible shortfall you then close by adding capacity is the whole talk
in one number — Beat 2 closes it, Beat 5 explains why it was there.

---

## Beat 1 — Backup (22:00) — ▶ START IT BEFORE YOU EXPLAIN IT

> _"Start a full Medusa backup from `manifests/cassandra/medusa-backup-job.yaml`, then
> watch the job and tell me as each node finishes."_

**~4–5 min at size 3.** Measured at size 6: 47.84 GB, 4,732 files, 6/6 nodes, 8m38s.

Talk while it uploads:
- **In-cluster S3.** MinIO on a Ceph volume, same namespace as Cassandra. No AWS
  account, no IAM request, no ticket to a cloud team.
- `s3_compatible`, not `s3` — explicit host instead of an AWS region. **The same five
  lines point at MinIO, AWS S3 or GCS.** That is why this runs on a cluster with no
  cloud account attached.
- The work is done by the **medusa container inside every Cassandra pod** — point back
  at the cold open.

> _"Show me the finished MedusaBackup objects with per-node sizes."_

🎤 *If asked why not ODF's object gateway:* tried it, its agent pods are pinned at
400Mi by the operator and were OOMKilled ~75 s in; three mitigations all failed. Good
answer to a question, **not a slide**.

---

## Beat 2 — Scale 3 → 6 (28:00) — ▶ START IT, THEN TALK

> _"Scale the `demo` K8ssandraCluster from 3 nodes to 6."_

**Watch which patch it picks.** A strategic-merge patch is rejected with "storageConfig
must be defined" — it must be a JSON patch on `/spec/cassandra/datacenters/0/size`. A
real Kubernetes trap, made visible for free.

> _"Watch the scale-up. Every 30 seconds tell me the ring status, which node is joining,
> and whether throughput dipped."_

⚠️ **9 min 20 s**, so it finishes *during* the MCP segment. That is intentional.

🎯 **The payoff: the gap from the cold open closes.** You opened saying the cluster
wanted 60k and gave 52.5k. Doubling the ring is the answer to exactly that, and they
have been looking at the shortfall for half an hour. Call it as the last node joins:

> _"That's the number I asked you to hold. We were twelve percent short because three
> pods were pinned against a CPU limit. Same limit — twice the pods."_

✅ **VERIFIED 22 Sep on the corrected dataset.** The gap does not just close — it
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
clear the backlog before settling back to the 60k rate limit. The throughput line
visibly jumps *past* the target and then flattens onto it.

> _"It's not just hitting sixty thousand now — it's running ahead to make up what it
> couldn't do for the last hour. Watch it settle back onto the target."_

Be precise if asked: **60k is the rate limit, not the ceiling.** The overshoot is
catch-up. What was measured is that the ceiling is no longer below the ask.

Material to fill ~6 minutes:
- Each rack 1 → 2; `size` must be a multiple of 3
- **The compromise, out loud:** three workers means two replicas per node. At RF=3 /
  LOCAL_QUORUM, losing one node now costs two of three replicas. You would not do this
  in production — `/expert` says exactly that, which sets up Beat 5.
- **Racks don't have to be AZs.** No zone labels on this cluster; these are three
  workers with a label. A rack is a *logical* failure domain. Most portable idea here.
- Zero-Copy Streaming — file-level, not row by row
- The operator does one node at a time, waiting for each to join. That used to be you,
  a runbook, and a Slack thread.

> ⚠️ Scale-up throughput figures from 17 Sep were taken on the old dataset. Timings hold;
> re-measure ops/sec at the run-through.

---

## Beat 3 — MCP (36:00) — ⏸ THE SCALE LANDS DURING THIS BEAT

> _"Is the ring at 6 nodes yet? Give me each node's rack, load and ownership."_

**It will probably still be joining** — the scale started at 28:00 and needs 9m20s, so
it lands around 37:20. That is the better answer, not the worse one: you get a live
`UJ` node and an ownership split mid-flight, which is the most honest picture of what
the operator is doing. Ask again later in the segment and it will be 6/6.

That is MCP earning its place: the thing you started 8 minutes ago, verified in one
sentence instead of a terminal full of `nodetool`. **Do not kill anything until it
says 6/6** — that is Beat 4's gate, and you have until 42:00.

**Optional, once 6/6:** start a full repair of `payments` from the Reaper tab. Beat 4's
best line needs it ticking for a couple of minutes. **Never start it before the
scale** — a repair spanning 3 → 6 was never measured.

- **MCP in 30 seconds** — a standard for giving models tools. Server exposes tools →
  Claude calls them → results come back as context.
- **easy-cass-mcp** speaks CQL, runs in-cluster, reached over a Route with edge TLS.
- **Build narrow, not wide.** A generic Kubernetes MCP server dumps thousands of tokens
  for one `get pods`. This returns what matters, per node.
- **A second server, not mine:** Grafana ships its own, run read-only. Within ten
  minutes of connecting it, it caught a wrong number on this deck — the dashboard was
  double-counting cAdvisor series. *The AI made a claim I could check against two other
  sources, and checking is what found it.*

---

## Beat 4 — Kill a node (42:00)

> _"Force-kill the pod `demo-dc1-rack2-sts-1` — no grace period, no graceful drain.
> I want it to die the way a real node dies."_

**Ask for the force-kill explicitly.** A polite delete drains cleanly — that is a
rolling-restart demo, not a failure demo.

| | |
|---|---|
| Detected `DN` | ~24 s |
| Back to `UN` | **44 s** |
| Pod `3/3` | **64 s** |
| `unavailables` / `failures` | **0** / **0** |
| `timeouts` | **1**, over 10 min and ~36M ops |

**Quote the 1, not "zero".** More credible, and true.

🌟 **The line that lands — only if you started the repair at 6/6.** It **does not
notice the kill.** Segments kept
incrementing straight through (22 → 23 → 24), rate unchanged, Reaper never restarted.
Measured 21 Sep.

> _"What do you see now?"_

**Have ready:** NoSQLBench prints red `ConnectionInitException` warnings. Those are
**not query failures** — the driver rebuilding its pool against the new pod IP. Point
at `unavailables` and `timeouts`: *"no query failed; that's a pool reconnect."*

---

## Beat 5 — Skills (48:00) — 🚫 NOTHING IS MUTATED HERE

Three panels, one skill, one decision. The segment least likely to fail on camera.

1. Grafana **CFS throttling** — and it is not subtle
2. **Worker node CPU** — ~20%. The host is bored
3. **Thread pool pending** — shallow. Nothing is queuing
4. `/diagnose` — three signals that only mean something together

**MEASURED 22 Sep**, size 3, under load:

| | |
|---|---|
| Container CPU | **9.7 – 13.7** of a 14 limit (69–98%) |
| Throttled periods | **27 – 88%** |
| Worker node CPU | **~20%** |
| Client errors | **0** |

**The whole argument in one sentence:** the pod is held down 88% of the time while the
worker it sits on is 80% idle, and every signal Cassandra exposes says healthy.

Then the second failure, from the rehearsal screenshots: disks filled,
`commit_failure_policy: stop` halted CQL and gossip **but left the JVM running** — pods
`3/3 Running`, `nodetool status` `DN`. One failure invisible to Cassandra, one
invisible to Kubernetes.

Land it as a **decision, not a fix**:

> _"The skill is telling me I'm leaving throughput on the floor. I know. That limit is
> sized for two pods per worker after the scale-up, and I'd rather show you a
> constrained cluster honestly than a tuned one. I measured what fixing it buys —
> throttling goes to 0.3%, p99 read halves — and I'm choosing not to."_

⛔ **Do NOT raise the CPU limit live.** A CR edit triggers a rolling restart, measured
at **9.1–9.7 min** — longer than this whole segment.

---

## Failure playbook

| If this happens | Do this |
|---|---|
| **Grafana MCP returns 401** | You didn't restart Claude Code after the deploy. Token is minted fresh each run and read once at startup. Restart, or use the Grafana tab. |
| **Claude proposes `kubectl apply -f k8ssandra-cluster.yaml`** | **Stop it.** The manifest says `size: 3`; applying mid-talk decommissions three nodes. |
| **Medusa: "backup already exists"** | Metadata lives in the bucket, not Kubernetes. Use a new name. |
| **Scale looks hung** | It's 9m20s, not 6. Check `nodetool status` for `UJ`. |
| **Ring not 6/6 at Beat 4** | Wait. Do not kill a node mid-bootstrap. Stretch Beat 3. |
| **Claude picks a wrong approach** | Correct it in one sentence and move on. Better demo than a flawless one — it shows the loop has a human in it. |

---

## Numbers card

Anything measured before **22 Sep** was taken on a dataset averaging 1.4 rows per
partition and is not comparable — those figures are gone, not footnoted.

| | |
|---|---|
| Throughput | **52,527 ops/sec** (44,648 R + 7,879 W, 85/15) |
| p99 read / write | **39 ms / 20 ms** · p50 **3.0 / 1.4 ms** |
| Client errors | **0** |
| CPU | **9.7 – 13.7** of 14 · **27 – 88%** throttled |
| Scale 3→6 | **9m20s**, 0 errors |
| Node kill | `UN` **44 s**, 3/3 **64 s**, 1 timeout |
| Backup | **47.84 GB, 4,732 files, 8m38s** (size 6) → ~4–5 min at size 3 |
| Repair | 436 segments, ~2/min, completed in **3h 40m** |
| Rolling restart (any CR edit) | **9.1 – 9.7 min** |
| Dataset | **9.8 GB/node**, 673k partitions, max 71.5 MB |

---

## Pre-show (see the runbook in the outline)

Ring at **size 3** · dataset loaded · NoSQLBench running ~60 min · Reaper registered,
**no repair running** (start it after the scale, if at all) · Grafana + Reaper tabs open
and logged in · **Claude Code restarted** and both MCP servers answering.

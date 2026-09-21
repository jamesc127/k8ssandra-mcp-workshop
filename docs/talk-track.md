# Talk Track — Control C* Con Claude Code

**Wed 23 Sep, 12:00 Central.** 60 min + ~10 min Q&A.

This is the **run sheet**: what you do, when, how long it actually takes, and what
to say while it runs. `docs/talk-outline.md` is the design doc and holds the
reasoning — this holds the clock. Every duration here is **measured on this
cluster**, not estimated.

---

## The one thing that will bite you

**Three demos run longer than the segment that starts them.** They are meant to.
Start them early and talk over them; do not wait for them.

| Beat | Starts in | Actually takes | Finishes during |
|---|---|---|---|
| Reaper repair | 5b (~14 min) | **3.6 h** — never finishes | you check it in Part 8 |
| Medusa backup | 5c (~24 min) | **~4–5 min** at size 3 | Part 5c, just barely |
| Scale 3 → 6 | 6 (~36 min) | **9 min 20 s** | ~3 min into Part 7 |

⚠️ **The scale-up is 9m20s and Part 6 is budgeted 6 minutes.** That is by design —
Part 7 begins while nodes are still joining — but it means **you must not kill a node
in Part 7 until the ring is 6/6 UN.** Check before you kill.

---

## Clock

| Clock | Part | Live beat |
|---|---:|---|
| 0:00 | 0 — Cold open | pods + nodes, Grafana already at 60k |
| 3:00 | 1 — Journey | — |
| 5:00 | 2 — Dark ages | — |
| 8:00 | 3 — K8s pain | — |
| 12:00 | 4 — k8ssandra | CRD map, live |
| 24:00 | 5a — Monitoring | ServiceMonitor + Grafana |
| 28:00 | **5b — Reaper** | ▶ **START REPAIR** |
| 32:00 | **5c — Medusa** | ▶ **START BACKUP** (first thing!) |
| 36:00 | **6 — Scale** | ▶ **START SCALE 3→6** |
| 42:00 | 7 — MCP | ⏸ wait for 6/6 UN, then ▶ **KILL NODE** |
| 49:00 | 8 — Skills | check Reaper %, `/diagnose` |
| 57:00 | 9 — Close | — |
| 60:00 | Q&A | |

---

## Beat 1 — Cold open (0:00)

> _"Show me every pod in the default namespace, with the node each one landed on."_

> _"List the worker nodes with their workload and rack labels, and which are tainted."_

Then Grafana tab — **~60,000 ops/sec**, an hour of history already on screen.

> _"Everything you're about to see is live. It's been running for an hour, it's under
> load right now, and I'm not going to stop it for the rest of the talk."_

---

## Beat 2 — Reaper (28:00) — ▶ START REPAIR

**Do this first, then explain.** It runs for the rest of the talk.

Reaper UI → `demo` → Repair → keyspace `payments` → full, PARALLEL → Start.

| | |
|---|---|
| Total segments | **436** |
| Rate | **~2 segments/min** (one tick every ~30 s) |
| Full run | **~3.6 h** — it will NOT finish |
| Where it'll be in Part 8 | **12–15%**, ~55–65 segments |

**Say the slow rate is the point.** A multi-hour job split into hundreds of resumable
segments, paced against live traffic, is exactly what you don't run by hand. If it
finished inside a talk, nobody would need the tool.

While segments tick: zombie data — writes fail, hints expire, nodes miss mutations;
if a delete isn't repaired before `gc_grace_seconds` the tombstone is collected and
the row comes back.

---

## Beat 3 — Medusa (32:00) — ▶ START BACKUP FIRST

> _"Start a full Medusa backup from `manifests/cassandra/medusa-backup-job.yaml`,
> then watch the MedusaBackupJob and tell me as each node finishes."_

**Start it before you say anything else.** At size 3 it needs ~4–5 min and the segment
is 4. Measured at size 6: **47.84 GB, 4,732 files, 6/6 nodes, 8m38s.**

Talk while it uploads:
- S3 endpoint is **in-cluster** — MinIO on a Ceph volume, same namespace as Cassandra.
  No AWS account, no IAM request, no ticket to a cloud team.
- `s3_compatible`, not `s3` — an explicit host instead of an AWS region. **The same
  five lines point at MinIO, AWS S3 or GCS.** That portability is load-bearing: it's
  why this runs on a cluster with no cloud account attached.
- The sidecar doing the work is the **medusa container inside every Cassandra pod** —
  point back at Beat 1's pod list.

Payoff:

> _"Show me the finished MedusaBackup objects with per-node sizes, and how much is
> now in the MinIO bucket."_

🎤 **If asked "why not ODF's object gateway?"** — tried it, couldn't carry the load.
Its agent pods are pinned at 400Mi by the operator and were OOMKilled ~75 s into a
full backup; three mitigations all failed. Good answer to a question, **not a slide**.

---

## Beat 4 — Scale 3 → 6 (36:00) — ▶ START SCALE

> _"Scale the `demo` K8ssandraCluster from 3 nodes to 6."_

**Watch which patch it picks.** A strategic-merge patch is rejected with
"storageConfig must be defined"; it has to be a JSON patch on
`/spec/cassandra/datacenters/0/size`. Non-obvious trap, made visible for free.

Then hand off the narration:

> _"Watch the scale-up. Every 30 seconds tell me the ring status, which node is
> joining, and whether throughput dipped."_

**MEASURED 17 Sep:**

| | |
|---|---|
| To 6 nodes UN | **9 min 20 s** |
| First new node joined | ~2 min |
| Throughput | 55.5k – 60.1k against 60k |
| Worst dip | **8%**, recovered in 25 s |
| NoSQLBench errors | **0** |
| Ownership | 100% → 51.5% / 48.5% |

~6 minutes of material to fill:
- Each rack 1 → 2; `size` must be a multiple of 3
- **The compromise, said out loud:** three workers means two replicas per node. At
  RF=3 / LOCAL_QUORUM, losing one node now costs two of three replicas. You would not
  do this in production — `/expert` says exactly that, which sets up Part 8.
- **Racks don't have to be AZs.** No zone labels on this cluster at all; these are
  three worker nodes with a label. A rack is a *logical* failure domain. Most portable
  idea in the talk.
- Zero-Copy Streaming: file-level, 42–138 MB/node in 6.7–9.8 s
- The operator does one node at a time, waiting for each to join — the runbook and
  Slack thread you used to be

---

## Beat 5 — Kill a node (42:00) — ⏸ CHECK FIRST

🛑 **Confirm 6/6 UN before killing.** The scale from Beat 4 needs ~9m20s and Part 7
starts at 6:00. Ask first:

> _"Is the ring at 6 nodes, all UN?"_

Then:

> _"Force-kill the pod `demo-dc1-rack2-sts-1` — no grace period, no graceful drain.
> I want it to die the way a real node dies."_

**Ask for the force-kill explicitly.** A polite delete drains cleanly — that's a
rolling-restart demo, not a failure demo, and the recovery time stops meaning anything.

**MEASURED 17 Sep**, at 60,014 ops/sec:

| | |
|---|---|
| Detected `DN` | ~24 s |
| Back to `UN` | **44 s** |
| Pod `3/3` | **64 s** |
| Throughput | 60,267 → 57,082 → 59,373 (~5% dip) |
| `unavailables` / `failures` | **0** / **0** |
| `timeouts` | **1**, over 10 min and ~36M ops |

**Quote the 1, not "zero".** More credible, and it's the truth.

🌟 **The line that lands, measured 21 Sep:** the Reaper repair from Beat 2 is still
running while you do this — and **it does not notice.** Segments kept incrementing
straight through the kill (22 → 23 → 24), rate unchanged, Reaper never restarted.
Kill a node mid-repair in front of the audience and the repair carries on.

Then:

> _"What do you see now?"_

**Have ready:** NoSQLBench prints red `ConnectionInitException` warnings. Those are
**not query failures** — it's the driver's admin thread rebuilding its pool against
the new pod IP, backing off 8.7 → 14.9 → 21.9 → 30.9 s. Point at `unavailables` and
`timeouts`: *"no query failed; that's a pool reconnect."*

---

## Beat 6 — Skills (49:00)

1. Grafana **CFS throttling** — non-zero
2. **Worker node CPU** — twenty-something percent
3. **Thread pool pending** — shallow
4. `/diagnose` — three signals that only mean something together

**The sharpened point:** the pod is throttled at **~60% of its CPU quota**. CFS accounts
in 100 ms periods, so a burst empties the slice inside one period while the 5-minute
average looks fine. *"We were only at 60% and still throttled"* beats *"we hit the limit."*

**Check Reaper here** — expect **12–15%**. Say the percentage; don't imply it's nearly done.

| | Size 3 (17 Sep) | Size 6 (21 Sep) |
|---|---|---|
| Container CPU | 6.7 – 8.8 cores | 3.4 – 4.0 |
| Limit | 14 | 14 |
| Throttled periods | **peaks 6.7%** | 0.5 – 1.0% |
| Worker node CPU | 24 – 36% | ~20% |

---

## Failure playbook

| If this happens | Do this |
|---|---|
| **Grafana MCP returns 401** | You didn't restart Claude Code after the deploy. The token is minted fresh every run and `mcp-grafana` reads it once at startup. Restart, or drop to the Grafana tab. |
| **Claude proposes `kubectl apply -f k8ssandra-cluster.yaml`** | **Stop it.** The manifest says `size: 3`; applying mid-talk decommissions three nodes. Patch the field. |
| **Medusa: "backup already exists"** | Metadata lives in the bucket, not Kubernetes. Use a new name. |
| **Scale-up looks hung** | Bootstraps are serial and it's 9m20s, not 6. Check `nodetool status` for `UJ`. |
| **Reaper pod restarted** | Expected if every pod rolled; it self-recovers and the repair resumes. A single node kill does *not* bother it. |
| **Claude picks a wrong approach live** | Correct it in one sentence and move on. That's a better demo than a flawless one — it shows the loop has a human in it. |

---

## Numbers card

| | |
|---|---|
| Throughput | **59,997 ops/sec** (50,997 R + 9,000 W, 85/15) |
| Soak proven | 324,000,000 cycles, 90 min, **0 errors** |
| Scale 3→6 | **9m20s**, 0 errors, 8% dip |
| Node kill | `UN` in **44 s**, 3/3 in 64 s, 1 timeout |
| Backup | **47.84 GB, 4,732 files, 8m38s** (size 6) |
| Repair | **436 segments, ~2/min, 3.6 h** |
| Dataset | 8.3 GB/node, 222.7 MB per 1M txns/node |

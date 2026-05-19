# From YAML Hell to AI Ops: Managing Cassandra with MCP and Skills

**Format:** 20-minute talk + live demo
**Repo:** k8ssandra-workshop
**Companion repos:**
- MCP server: [rustyrazorblade/easy-cass-mcp](https://github.com/rustyrazorblade/easy-cass-mcp)
- Skills: [rustyrazorblade/skills](https://github.com/rustyrazorblade/skills)

**Style:** Heavy live demo — Claude Code open on screen throughout Parts 3, 4, and 5

---

## Opening (~1 min) — The Cassandra Consultant's Journey

- Speaker intro: background as a Cassandra consultant
- Thesis: AI tooling is changing how we operate databases — but there are multiple approaches with real tradeoffs
- Roadmap: hand-editing → operators → MCP → skills
- _"By the end of this talk, I'm going to restart a Cassandra node in front of you while a load test is running, and we're going to ask Claude what happened."_

---

## Part 1 (~2 min) — Hand-Editing YAMLs: The Dark Ages

- Life as a C* consultant: `cassandra.yaml`, `cassandra-env.sh`, `jvm.options` — across N nodes, by hand
- Seed lists, rack assignments, snitch configs, GC tuning — all bespoke per cluster
- Config drift is the real enemy: one wrong indent and a node won't join the ring
- Rolling restarts: SSH into each node in order, pray nothing times out, repeat
- _"I've seen more YAML than my family"_

---

## Part 2 (~3 min) — Cassandra Meets Kubernetes: Hope and Pain

- **The promise:** declarative infrastructure, self-healing, automated scaling
- **Early attempts:** hand-rolled StatefulSets, init containers for seed discovery, manual PV lifecycle
- **The hardest problems:**
  - Storage: PVCs don't follow pods; lose a node, orphan a volume
  - Rolling restarts: Kubernetes doesn't know about Cassandra's streaming/repair state
  - Rack-aware scheduling: node labels, pod anti-affinity rules, token math — all by hand
- **The industry tried to automate this:** Ansible, Terraform, Puppet — and they helped
  - Config drift got better once you figured out the variable escaping (eventually)
  - Deployments became more repeatable... as long as nothing went wrong mid-play
  - But these are still *imperative* tools at heart — they get you to a desired state, they don't *keep* you there
  - No self-healing: a dead node is still a dead node waiting for a human and an Ansible run
- **Enter k8ssandra-operator — show the diff:**
  - Before: hundreds of lines of StatefulSet YAML, init containers, headless services, custom scripts
  - After: **show `manifests/cassandra/k8ssandra-cluster.yaml`** — 25 lines, declare the desired state, done
  - Bundles Medusa (backups), Reaper (repairs), metrics — batteries included
- **The remaining gap:** the operator manages the cluster, but you still need expertise to *operate* it — diagnose problems, tune performance, know what's normal

---

## Part 3 (~3 min) — easy-cass-mcp: Giving AI Eyes on Your Cluster

- **EKS Architecture Overview** — show slides
- **What is MCP?** (30 seconds)
  - Model Context Protocol: a standard for giving AI models access to external tools
  - Server exposes tools → Claude calls them → results flow back as context
- **easy-cass-mcp** ([rustyrazorblade/easy-cass-mcp](https://github.com/rustyrazorblade/easy-cass-mcp)):
  - Domain-specific MCP server that speaks CQL fluently, deployed in-cluster
  - Architecture: Claude Code → internet-facing NLB → easy-cass-mcp pod → Cassandra pods
  - The tools that do the work:

    | Tool | What it does |
    |---|---|
    | `query_all_nodes(cql)` | Fans out a CQL query to every replica, labels results by node — essential for the `system_views.*` per-node virtual tables |
    | `query_node(addr, cql)` | Targets a single replica for deep dives |
    | `query_system_table(keyspace, table)` | Curated access to system keyspaces (peers, local, sstable_activity, ...) |
    | `get_create_table(keyspace, table)` | Pulls canonical schema — feeds data-model analysis |
    | `analyze_table_optimizations(keyspace, table)` | Version-aware compaction recommendations |

- **Build narrow, not wide:**
  - Tried a generic Kubernetes MCP server first — a single `get pods` dumps thousands of tokens of labels, annotations, status conditions
  - easy-cass-mcp returns only what's relevant, structured by node — Claude doesn't drown in metadata
  - **Takeaway: MCP server *design* matters as much as MCP server existence.**
- **Time-to-first-insight:**
  - Traditional stack (JMX exporter sidecars + Prometheus + Grafana dashboards + alerting) = half a day, minimum
  - MCP + Claude Code = seconds, data lands as structured tables already labeled by node

### Live Demo — Node Restart Under Load

_Setup: NoSQLBench already running — 100k ops/sec, 50/50 read/write, RF=3, LOCAL_QUORUM_

**Step 1 — Ask Claude: "Is the cluster healthy?"**
- Claude calls `local_read_latency` and `local_write_latency` on all nodes via easy-cass-mcp
- Show live: even distribution, sub-millisecond latency everywhere, load test humming

**Step 2 — Kill a node, live, on screen:**
```
kubectl delete pod demo-dc1-default-sts-1
```
- Pod gone. StatefulSet immediately schedules a replacement.

**Step 3 — Ask Claude: "What do you see now?"**
- Claude queries the latency tables again — surfaces the anomaly:
  - Surviving nodes: counts in the hundreds of thousands, p99 ~0ms
  - New node: count only ~14k, rate ramping up, p99 slightly elevated
- Claude interprets: _"One node has significantly lower operation counts than its peers — consistent with a recent restart. The gap will close as the driver rebalances. Load test uninterrupted."_

**The point:** in the old world, that was a scheduled maintenance window with a runbook and a Slack thread. Here it's a 52-second demo with a natural-language debrief.

---

## Part 4 (~5 min) — Skills: Cassandra Expertise as Markdown

- **What is a skill?** A markdown file with trigger conditions and instructions, loaded into Claude Code's context on-demand — no running service, no deployment, just a markdown file
- **MCP vs. Skills — head to head:**

  | | MCP Server | Claude Code Skill |
  |---|---|---|
  | **What it is** | Running service exposing tools via protocol | Markdown file with instructions |
  | **Where it runs** | Separate process or container | Loaded into the agent's context window |
  | **What it provides** | Live data access (query, mutate) | Domain knowledge and procedures |
  | **Context cost** | Each tool call's results fill the window | Loaded once when triggered |
  | **Maintenance** | Write code, deploy, monitor a service | Edit a markdown file |
  | **Best for** | Real-time data, actions with side effects | Runbooks, deployment playbooks, troubleshooting |
  | **Limitation** | Generic servers bloat context; needs infra | No live data access; static knowledge only |

- **MCP and skills together:**
  - MCP = data plane access (what's happening right now)
  - Skills = control plane knowledge (what to do about it)
  - Together: the skill tells Claude *how*; MCP lets Claude *verify*

### Three Cassandra skills, three lenses ([rustyrazorblade/skills](https://github.com/rustyrazorblade/skills))

All three operate on the same MCP-collected data, each with a different stance:

| Skill | Lens | Output style |
|---|---|---|
| `/diagnose` | USE method (Utilization / Saturation / Errors) across all nodes | "Here's what's wrong (or right) and why" |
| `/optimize` | Tier-ranked tuning: `cassandra.yaml` + `ALTER TABLE` deltas | "Apply these in order, expected impact: X" |
| `/expert` | Opinionated big-picture — anti-patterns, trade-offs, production-readiness | "Here's what I'd actually do, and why" |

These aren't generic "ask an LLM" wrappers. They apply USE-method diagnostics, published Cassandra-community stances on `num_tokens` and compaction, and version-specific C* 5 features (UCS, Trie memtables, BTI, Zero-Copy Streaming) — codified once, applied every time.

### Live Demo — The Analysis Loop

_Setup: NoSQLBench has been running at 100k ops/sec for an hour; cluster has been scaled live 3 → 6 → 9 nodes during the run_

Loose talking points — find the live moments as they come, but cover:

- **`/diagnose` fans out via `query_all_nodes`** against `system_views.*` and compares all 9 nodes. The headline find: pods pegged at 6.0/6.0 CPU, but EC2 hosts at 30–70%, and *zero pending thread-pool tasks*. That's CFS throttling at the cgroup level — invisible to `tpstats`, invisible to flat dashboards. It accounts for the 8k-ops/sec shortfall between achieved (~92k) and target (100k).

- **`/optimize` tier-ranks the fix.** Highlight the Tier-1 surprise: the operator default ships `key_cache_size_in_mb: 0`, but the table requests `caching: {keys: ALL}`. The table-level setting is silently meaningless without the YAML setting. Also call out: drop compression chunk size from 16 KiB to 4 KiB (250× I/O amp on point lookups), raise the CPU limit. Tier 2 covers `num_tokens: 16 → 4`, Trie memtables, `commitlog_sync_period`. Expected total impact: ~92k → ~110–120k ops/sec on the same hardware.

- **`/expert` quotables** to drop in as fits:
  - "softPodAntiAffinity is defensible only for dev/CI/workshop — not for any RF=3 cluster where availability matters."
  - "In 2018 this was a multi-day project; in 2026 it's a kubectl one-liner."

**The durable insight: the operator defaults shipped five production tunings missed, and the MCP-plus-skills loop surfaced all of them in under an hour.** That's expert-grade analysis, automated.

- **Two skills, two scopes — same mechanism:**
  - `cassandra-k8s-deploy`: general expertise, taken everywhere — EKS/GKE/AKS, Medusa, Reaper, TLS, auth
  - `k8ssandra-workshop`: project-specific runbook for this repo — exact manifests, namespaces, MCP tool selection, load-test procedures
  - `k8ssandra-workshop` explicitly supersedes `cassandra-k8s-deploy` when in this repo — no ambiguity

---

## Part 5 (~3 min) — Scale Under Load: The Headline "Just Works" Moment

If you take one thing from this session: **scaling Apache Cassandra under load is no longer an event.**

- **Live, on screen, while NoSQLBench is hammering at 100k ops/sec:**

  ```
  kubectl patch k8ssandracluster demo --type=json \
    -p='[{"op":"replace","path":"/spec/cassandra/datacenters/0/size","value":9}]'
  ```

- **Six minutes later: 9 nodes in the ring. While that happened:**
  - 3 → 6 added 3 nodes in ~5.5 minutes, one bootstrap at a time
  - 6 → 9 added 3 more in ~5.4 minutes
  - Each new node streamed 42–138 MB of data in 6.7–9.8 seconds via Zero-Copy Streaming
  - Existing nodes kept serving 100k ops/sec — zero NB errors throughout
  - Driver token-aware policy picked up new coordinators within seconds of gossip propagation
  - RF=3 maintained continuously

- **Throughput climbed roughly linearly:**
  - ~32k ops/sec (3 nodes) → ~85k (6 nodes) → ~105k (9 nodes, after driver pool warmed)
  - Exactly the shape it should be

- **What made this possible** — and worth naming explicitly:
  - The **operator** managed the orchestration and PV lifecycle
  - **Zero-Copy Streaming** made bootstraps complete in seconds, not hours
  - **MCP** gave us live observation through the scale event
  - **Skills** gave us the framework to reason about whether what we saw was healthy
  - All from a single Claude Code chat — no Grafana, no JMX hand-rolling, no kubectl-exec loops

The operator alone manages the cluster. The full loop *operates* it.

---

## Closing (~1 min) — The Stack of the Future

- **The full picture:** Operator manages the cluster · MCP gives AI live access · Skills give AI the knowledge to act
- **Three things to take home:**
  1. Build domain-specific MCP servers — not generic ones. Context windows are precious.
  2. Turn your runbooks into skills. If you wrote it down, Claude can follow it.
  3. Combine both: MCP for observation, skills for action.
- **Links:**
  - This workshop repo
  - MCP server: [rustyrazorblade/easy-cass-mcp](https://github.com/rustyrazorblade/easy-cass-mcp)
  - Skills: [rustyrazorblade/skills](https://github.com/rustyrazorblade/skills)
- Q&A

# From YAML Hell to AI Ops: Managing Cassandra with MCP and Skills

**Format:** 15-minute lightning talk
**Repo:** k8ssandra-workshop
**Style:** Heavy live demo — Claude Code open on screen throughout Acts 3 & 4

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

## Part 3 (~4 min) — MCP + Live Demo: Giving AI Eyes on Your Cluster

- **What is MCP?** (30 seconds)
  - Model Context Protocol: a standard for giving AI models access to external tools
  - Server exposes tools → Claude calls them → results flow back as context
- **easy-cass-mcp:** a domain-specific MCP server that speaks CQL, deployed in-cluster
  - Architecture: Claude Code → internet-facing NLB → easy-cass-mcp pod → Cassandra pods
- **The "containers" MCP gotcha — before the demo:**
  - Tried a generic Kubernetes MCP server first — it dumps the entire cluster state into the context window
  - A single "get pods" returns thousands of tokens: labels, annotations, status conditions, container specs
  - The model drowns in metadata; easy-cass-mcp returns exactly what's needed, nothing more
  - **Takeaway: MCP server design matters as much as MCP server existence. Build narrow, not wide.**

### Live Demo — Node Restart Under Load

_Setup: NoSQLBench already running — 1,000 ops/sec, 50/50 read/write, RF=3, LOCAL_QUORUM_

**Step 1 — Ask Claude: "Is the cluster healthy?"**
- Claude calls `local_read_latency` and `local_write_latency` on all 3 nodes via easy-cass-mcp
- Show live: even read distribution (~350–400 ops/s per node), sub-millisecond latency everywhere, load test humming

**Step 2 — Kill a node, live, on screen:**
```
kubectl delete pod demo-dc1-default-sts-1
```
- Pod gone. StatefulSet immediately schedules a replacement.

**Step 3 — Ask Claude: "What do you see now?"**
- Claude queries latency tables again — surfaces the anomaly:
  - Two nodes: counts in the hundreds of thousands, rate ~400 ops/s, p99 ~0ms
  - New node: count only ~14k, rate ~140 ops/s ramping up, p99 slightly elevated
- Claude interprets: _"One node has significantly lower operation counts than its peers — consistent with a recent restart. Latency is normal and the count gap will close as the driver rebalances connections. The load test was uninterrupted throughout."_
- New pod IP assigned automatically — gossip handled it, no config change needed

**The point:** in the old world, that was a scheduled maintenance window with a runbook and a Slack thread. Here it's a 52-second demo with a natural language debrief.

---

## Part 4 (~3 min) — Skills: Teaching the Agent, Not Just Connecting It

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

### Live Demo — Skill Trigger on Screen

_Ask Claude: "scale the Cassandra cluster to 4 nodes"_

- `k8ssandra-workshop` skill auto-triggers from the request
- Claude reads the skill, runs the `kubectl patch` command directly — no intermediate tooling
- Show the skill file briefly: it's just markdown — trigger description, a set of procedures, kubectl commands
- **The insight:** this is your runbook, but Claude follows it

- **Two skills, two scopes — and that's the point:**
  - `cassandra-k8s-deploy`: general expertise, taken everywhere — EKS, GKE, AKS, Medusa backups, Reaper repairs, TLS, auth
  - `k8ssandra-workshop`: project-specific runbook for this repo — exact manifests, namespaces, MCP tool selection, load test procedures
  - Same mechanism, different scope: just like how an engineer carries general expertise into every project, then writes a project-specific runbook on top
  - `k8ssandra-workshop` explicitly supersedes `cassandra-k8s-deploy` when working in this repo — no ambiguity
- **MCP and skills together:**
  - MCP = data plane access (what's happening right now)
  - Skills = control plane knowledge (what to do about it)
  - Together: the skill tells Claude *how* to scale; MCP lets Claude *verify* it worked

---

## Closing (~1 min) — The Stack of the Future

- **The full picture:** Operator manages the cluster · MCP gives AI live access · Skills give AI the knowledge to act
- **Three things to take home:**
  1. Build domain-specific MCP servers — not generic ones. Context windows are precious.
  2. Turn your runbooks into skills. If you wrote it down, Claude can follow it.
  3. Combine both: MCP for observation, skills for action.
- Link to repo + Q&A

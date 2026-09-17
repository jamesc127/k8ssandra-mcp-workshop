# Dress Rehearsal Checklist

For the Planet Cassandra #18 talk, 23 September 2026. Two passes: one on the
18th to find problems, one on the 22nd to time the talk.

The **talk-day** T-180 sequence lives at the end of `talk-outline.md`. This file
is the rehearsal, which is a different job: the point is to break things while
it is still cheap.

```bash
export KUBECONFIG=$PWD/conf_kubeconfig_itz-ckzpiv.conf
```

---

## 0. Preflight (5 min)

- [ ] `kubectl get nodes -L workload,k8ssandra.io/rack` — 3 racks, tainted loadgen, utility
- [ ] `kubectl get pods -n default` — 3 Cassandra 3/3, Reaper, MCP, both operators
- [ ] `nodetool status` — three `UN`. **Do not trust `kubectl get pods` for this**; a node
      can be dead in the ring while its pod reports 3/3
- [ ] `kubectl get k8ssandracluster demo -o jsonpath='{.status.error}'` — must be empty.
      This is where webhook rejections hide, and a rejected write silently blocks every
      config change in the same apply
- [ ] Grafana panel 11 (PVC usage) under 40%, panel 13 (hours to full) comfortable

---

## 1. Data (should already be loaded)

- [ ] `nodetool tablestats payments.transactions_by_card` — roughly 50M partitions,
      compression around 0.5, mean partition ~326 bytes
- [ ] Total Load per node **≥ 10 GB**
- [ ] Spot-check that buckets agree with timestamps:
      `SELECT card_id,bucket,txn_at FROM payments.transactions_by_card LIMIT 5;`
      `2026-M0` must be a March date, `2026-M6` a September one

If the data is missing or wrong, reload — it is ~47 minutes, so discover this on the
18th, not the 22nd.

---

## 2. Start the load and let it settle

```bash
kubectl apply -f manifests/loadtest/nosqlbench-payments-job.yaml
```

- [ ] Confirm the pod lands on the **loadgen** node (`-o wide`)
- [ ] Let it run **60 minutes** before judging any latency number. The driver pool
      warms, UCS reaches a stable sstable count, and Grafana needs history to look like
      anything
- [ ] While it soaks, do section 3

---

## 3. Prove the things that fail silently

These are the ones that look fine until they are not. All of them have bitten this
cluster at least once.

- [ ] **Grafana panels render.** Every panel returns series — especially 7-13, which come
      from the Thanos datasource. An empty panel usually means the datasource token expired
- [ ] **ServiceMonitors exist:** `kubectl get servicemonitor -n default` (expect 2).
      If empty, the operator never saw the CRD — restart it
- [ ] **MCP answers:** ask Claude to run `query_all_nodes` and confirm all three racks reply
- [ ] **Reaper registered the cluster** — open the UI, confirm `demo` is listed
- [ ] **Medusa can actually reach NooBaa** — run a backup to completion, *then delete it*
      so the on-camera one is a genuine first full backup:
      ```bash
      kubectl apply -f manifests/cassandra/medusa-backup-job.yaml
      kubectl get medusabackup -n default          # expect SUCCESS, 3/3 nodes
      kubectl delete medusabackupjob demo-talk-backup -n default
      ```

---

## 4. Rehearse each live moment, in talk order

- [ ] **Part 0 cold open** — `kubectl get pods -o wide`, `kubectl get nodes -L ...`,
      Grafana already showing throughput
- [ ] **Part 4c** — `kubectl get crds | grep k8ssandra`, `kubectl explain k8ssandracluster.spec`
- [ ] **Part 5a** — Grafana tour
- [ ] **Part 5b** — trigger a Reaper repair on `payments`, leave it running
- [ ] **Part 5c** — Medusa backup on camera; time it
- [ ] **Part 6 — scale 3 → 6.** The riskiest moment. Time it end to end. Then **scale back
      to 3** so the next rehearsal starts from the same state
- [ ] **Part 7** — `kubectl delete pod demo-dc1-rack2-sts-0`, then ask Claude what changed
- [ ] **Part 8** — `/diagnose`, the CFS throttling panel, then raise the CPU limit and watch
      panel 8 fall. Check the Reaper repair from 5b has progressed

---

## 5. Capture numbers

The outline has «MEASURE AT REHEARSAL» markers. Fill in every one:

- [ ] Sustained ops/sec, and the read/write split
- [ ] p50 and p99 client latency (microseconds — verified against `nodetool`)
- [ ] CFS throttling %, and node CPU % alongside it
- [ ] Scale 3 → 6 wall-clock, and whether the rate held
- [ ] Medusa backup duration, Reaper repair duration
- [ ] Load per node

**Quote what you measured, not what you hoped.** These numbers come from a deliberately
CPU-limited cluster; say so.

---

## 6. Capture fallbacks

- [ ] Screenshot every live moment — these become backup slides if something fails on Zoom
- [ ] Screen-record the Medusa backup and the 3 → 6 scale specifically. They are the two
      longest and the two most likely to misbehave
- [ ] Keep `kubectl get pods` beside `nodetool status` from the disk-exhaustion event —
      Part 8 uses it

---

## 7. Lock it down (22nd only)

- [ ] Stop changing things. No chart bumps, no config edits after this point
- [ ] `claude_desktop_config.json` points at the current Route — **not** auto-updated,
      only the project `.mcp.json` is
- [ ] Confirm the reservation still covers the 23rd
- [ ] Leave the cluster at ring size **3**, data loaded, load stopped

---

## If it breaks

`docs/TROUBLESHOOTING.md` covers everything hit so far. The three that cost the most time:

| Symptom | Look at |
|---|---|
| Nodes DN but pods 3/3 Running | Disk. `df -h /var/lib/cassandra` on every pod |
| A CR change does nothing | `kubectl get k8ssandracluster demo -o jsonpath='{.status.error}'` |
| A panel is empty / no ServiceMonitor | Thanos token, or restart k8ssandra-operator |

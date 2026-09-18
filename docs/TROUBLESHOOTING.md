# Troubleshooting Guide

## EKS / Infrastructure Issues

### Pods stuck in Pending (ImagePullBackOff)
**Cause**: Nodes are in public subnets without NAT Gateway routing.
**Fix**: This should not happen if you created the cluster with the provided ClusterConfig (`manifests/infra/eksctl-cluster.yaml`), which sets `privateNetworking: true` to place all nodes in private subnets. If you used a custom VPC, ensure nodes are in private subnets with NAT Gateway access.

### StorageClass PVC failures — "provisioner is not supported"
**Cause**: Wrong EBS CSI provisioner or missing EBS CSI driver addon.
**Fix**: Use the `ebs-gp3` StorageClass from `manifests/infra/storageclass.yaml` (provisioner: `ebs.csi.aws.com`). Ensure the `aws-ebs-csi-driver` addon is installed — this is handled automatically by the provided ClusterConfig.

### NLB not provisioning — "unable to resolve at least one subnet"
**Cause**: Subnets missing required tags.
**Fix**: If you created the cluster with the provided ClusterConfig, eksctl tags subnets automatically. If you used a custom VPC, tag subnets manually:
- Public subnets: `kubernetes.io/role/elb=1`
- Private subnets: `kubernetes.io/role/internal-elb=1`

```bash
# Tag public subnets for internet-facing NLBs
aws ec2 create-tags --resources <PUBLIC_SUBNET_IDS> \
  --tags Key=kubernetes.io/role/elb,Value=1 --region us-east-1

# Tag private subnets for internal NLBs
aws ec2 create-tags --resources <PRIVATE_SUBNET_IDS> \
  --tags Key=kubernetes.io/role/internal-elb,Value=1 --region us-east-1
```

## k8ssandra-operator Issues

### Webhook "service not found" when creating K8ssandraCluster
**Cause**: k8ssandra Helm chart deploys workloads to the Helm release namespace, but webhook configs may reference a different namespace.
**Fix**: Always install k8ssandra-operator into `--namespace default`:
```bash
helm install k8ssandra-operator k8ssandra/k8ssandra-operator --namespace default
```

### Cassandra bootstrap stalls when racks are enabled

**Symptom:** With a `racks:` block in the K8ssandraCluster CR, the first pod never
finishes joining; the ring stays stuck in bootstrap.

**Cause:** Cassandra's default `allocate_tokens_for_local_replication_factor=3`
needs at least 3 racks to allocate tokens. An earlier version of this workshop
tried 2 racks across `us-east-1a/1b` — eksctl had auto-selected only 2 AZs
because the ClusterConfig had no `availabilityZones:` key — and the token
allocator could not converge.

**Fix:** pin 3 AZs in the eksctl ClusterConfig, both at the top level and on the
Cassandra node group, so the ASG balances nodes evenly across them:

```yaml
availabilityZones: [us-east-1a, us-east-1b, us-east-1c]
```

Verify before applying the CR — `scripts/deploy.sh` gates on this:

```bash
kubectl get nodes -L topology.kubernetes.io/zone,workload
```

The workaround that used to be in the CR, `softPodAntiAffinity: true`, packs
multiple Cassandra pods onto one node and defeats the purpose of racks. It is no
longer needed and has been removed.

---

## Disk Exhaustion

### Nodes are DN but every pod says 3/3 Running

**This is the most misleading failure in the whole workshop.** `kubectl get pods` shows three
healthy Cassandra pods. `nodetool status` shows two of them `DN`.

```bash
kubectl get pods -l app.kubernetes.io/name=cassandra    # 3/3 Running, 3/3 Running, 3/3 Running
kubectl exec demo-dc1-rack1-sts-0 -c cassandra -- nodetool -u cassandra-admin -pw <pw> status
#   UN  10.129.2.173  ...  rack1
#   DN  10.131.0.91   ...  rack2
#   DN  10.131.2.31   ...  rack3
```

**Cause:** the data volume filled. The commitlog could not be written:

```
org.apache.cassandra.io.FSWriteError: java.io.IOException: No space left on device
ERROR [PERIODIC-COMMIT-LOG-SYNCER] Failed to persist commits to disk.
      Commit disk failure policy is stop; terminating thread.
```

`commit_failure_policy: stop` halts CQL and gossip **but leaves the JVM running**, so the
container never exits, the pod never restarts, and nothing in Kubernetes looks wrong. The
node is simply gone from the ring.

**Why it filled.** Storage was sized from the logical dataset (20M rows x ~550B = ~11 GB per
node). That is the wrong calculation. Cassandra is append-only: a sustained job overwriting
the same bounded key range still creates a new sstable generation per write, and UCS could
not merge them fast enough. Result: 66 live sstables, 44 GB, disks at 94-99% after ~75
minutes at ~30k writes/sec.

**Size for WRITE THROUGHPUT x DURATION, not for dataset size.**

**Prevention, in order of usefulness:**

1. **Grafana panel 13, "Projected hours until PVC full"** — a linear projection from the last
   30 minutes of growth. If it reads lower than the load job's remaining runtime, the cluster
   will go down before the job finishes. Panels 11 and 12 show usage % (orange 70, red 85)
   and absolute free space.
2. **`commit_failure_policy: die`** instead of `stop` (now set in all CRs). The JVM exits, the
   container terminates, the kubelet restarts it, and a persistent failure surfaces as
   CrashLoopBackOff — a signal Kubernetes already understands. `stop` is the right choice on a
   VM with systemd; on Kubernetes it hides the failure.
3. Note that Cassandra's own `table_live_disk_space_used` (dashboard panel 5) **under-reports**
   — it counts live sstables only, missing commitlog, snapshots and sstables pending deletion.
   Use the kubelet's `kubelet_volume_stats_*` for the truth.

**Recovery:** expand the PVCs. The ODF StorageClass has `allowVolumeExpansion: true`:

```bash
kubectl delete job nosqlbench-load -n default          # stop the bleeding first
for p in server-data-demo-dc1-rack{1,2,3}-sts-0; do
  kubectl patch pvc $p -n default -p '{"spec":{"resources":{"requests":{"storage":"150Gi"}}}}'
done
```

PVCs go to `Resizing` / `FileSystemResizePending`. A mounted, running pod resizes online; a
pod whose Cassandra has already died needs a restart to complete the filesystem resize.

---

### Disk keeps growing and neither `nodetool status` nor `listsnapshots` explains it

**Symptom:** the PVC is at 21% while `nodetool status` reports a Load of 7.6 GiB on a
150Gi volume. Nodes added later sit at 5-8% with identical Load. Nothing in Cassandra's
own output accounts for the difference.

**Cause:** `auto_snapshot` defaults to **true**, and it fires on both `DROP` and
`TRUNCATE`. The snapshot hard-links every sstable, so dropping a table frees nothing.
Replacing the `baselines.keyvalue` workload with the payments model left **59 GiB across
three nodes** under a `dropped-<timestamp>-keyvalue` tag — for a keyspace that no longer
exists in the schema at all:

```
$ nodetool describering baselines
error: No such keyspace: baselines
```

Only the three original nodes were affected. The nodes added a day later by the scale-out
bootstrapped *after* the drop, streamed live data only, and have no snapshot — which is
why the symptom looks like a scale-out artifact and is not one. **The split is by node
age, not by ring position.**

**The obvious check under-reports by 22 GiB.** `nodetool listsnapshots` prints the
snapshot as a line item and then omits it from its own total:

```
dropped-1789592404299-keyvalue  baselines  keyvalue  22.54 GiB  22.54 GiB  2026-09-16T21:00:04Z
...
Total TrueDiskSpaceUsed: 457.76 KiB      <-- counts only the three tiny payments snapshots
```

The total cannot attribute a snapshot whose keyspace is gone from the schema, so it
silently drops it. Between them, `nodetool status` Load (live data only) and
`listsnapshots` (total excludes it) said 7.6 GiB while the PVC said 31.7 GiB. **Read the
per-snapshot rows, never the total** — and note that the only view that told the truth
here was the Kubernetes disk panel, which is the same reason panels 11-13 exist.

**Fix — reclaim it.** The tag differs on every node, because each one snapshots
independently at drop time:

```bash
for p in demo-dc1-rack1-sts-0 demo-dc1-rack2-sts-0 demo-dc1-rack3-sts-0; do
  kubectl exec -n default $p -c cassandra -- nodetool listsnapshots   # record first
  kubectl exec -n default $p -c cassandra -- nodetool clearsnapshot --all
done
```

Safe to run under sustained load: 58 GiB was reclaimed across three nodes during a 60k
ops/sec run with zero timeouts and zero failures, and all six nodes stayed UN.

**Fix — stop it recurring.** All three CRs now set `auto_snapshot: false` in
`cassandraYaml`. This is right for a workshop cluster that is torn down, rebuilt and
reloaded repeatedly. **On a production cluster leave it `true`** — it is exactly what
saves you from a mistaken `DROP` — and prune deliberately instead.

Note this is a `cassandraYaml` change, so applying it to a live cluster triggers a
rolling restart. It costs nothing to leave until the next rebuild.

---

### Node restart-loops after a disk-full event: corrupt commitlog

**Symptom:** after freeing space, one node will not start. cass-operator logs
`Deleting stuck pod ... Reason: Pod got stuck after Cassandra container terminated` on a loop.

```
ERROR [main] JVMStabilityInspector - Exiting due to error while processing commit log during initialization.
org.apache.cassandra.db.commitlog.CommitLogReadHandler$CommitLogReadException:
  Encountered bad header at position 1769653 of commit log
  /opt/cassandra/data/commitlog/CommitLog-8-1789578847990.log
```

**Cause:** the disk filled *mid-write*, leaving a truncated segment. Cassandra refuses to
replay it and exits during startup, so the loop never resolves on its own.

**Is it safe to discard?** Yes, with RF=3. `references/general/commitlog.md`:

> With RF=3 and `LOCAL_QUORUM` writes, the data is already on multiple nodes — the practical
> durability risk of 1-2 second periodic sync is very low.

Every mutation in that segment was acknowledged at LOCAL_QUORUM, so it is already on two
other replicas. Discarding it costs consistency on this node only, which repair restores.

**Fix.** The `cassandra` container is dead, so exec into the **medusa** sidecar — it mounts the
same `server-data` volume at `/var/lib/cassandra`. Move the segment rather than deleting it,
so the decision is reversible:

```bash
kubectl exec demo-dc1-rack3-sts-0 -c medusa -n default -- sh -c \
  'mkdir -p /var/lib/cassandra/commitlog_corrupt && \
   mv /var/lib/cassandra/commitlog/CommitLog-8-<id>.log /var/lib/cassandra/commitlog_corrupt/'
```

The pod restarts on its own. If another segment is corrupt, the next startup names it — repeat.

**Then repair.** On Cassandra 4.0+, incremental repair is safe
(`references/general/repair.md`), so a normal Reaper repair on `baselines` is enough.

**Alternative:** `-Dcassandra.commitlog.ignorereplayerrors=true` skips bad segments without
moving files. Same data loss, and it is easy to leave switched on by accident — prefer
quarantining the file.

---

## Monitoring Issues

### Grafana dashboards render completely empty

**Cause:** For Cassandra newer than 4.0.3, k8ssandra-operator emits the *modern*
ServiceMonitor, scraping the management API on `port: metrics` (9000). Metric
names are `org_apache_cassandra_metrics_*`. Nearly every published k8ssandra
Grafana dashboard targets the older MCAC endpoint (9103) and its
`collectd_mcac_*` metric names, so every panel queries something that does not
exist.

**Fix:** build dashboards against the live metric names. Confirm what is actually
being scraped first:

```bash
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090
# then browse http://localhost:9090 and search for org_apache_cassandra_metrics
```

Setting `telemetry.mcac.enabled: true` restores the legacy endpoint and lets old
dashboards work, but it adds a sidecar per pod and depends on a deprecated
component — not recommended.

### No ServiceMonitor is created at all, and the CR shows no error

**Cause:** The operator decides whether to emit ServiceMonitors by checking
whether the ServiceMonitor CRD is registered, through a cached RESTMapper. If
kube-prometheus-stack is installed *after* the operator pod starts, the operator
never sees the CRD and skips telemetry silently.

**Fix:** install kube-prometheus-stack before k8ssandra-operator (this is the
order in `scripts/deploy.sh`), or restart the operator:

```bash
kubectl rollout restart deployment/k8ssandra-operator -n default
kubectl get servicemonitor -n default   # should be non-empty
```

---

## Medusa Issues

### Backups fail or hang when uploading to S3

**Cause:** The generated `medusa.ini` renders `secure` and `ssl_verify` as
`False` unless they are set explicitly in the CR.

**Fix:** set both in `spec.medusa.storageProperties`:

```yaml
secure: true
sslVerify: true
```

### Medusa sidecar has no AWS credentials

**Symptom:** `kubectl exec <pod> -c medusa -- env | grep AWS_` shows nothing.

**Cause:** The pod is not running under the IRSA service account.

**Fix:** confirm `spec.cassandra.serviceAccount: medusa-backup` is set in the CR,
and that the service account carries its role annotation:

```bash
kubectl get sa medusa-backup -n default \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
```

See `manifests/infra/medusa-irsa.md` for the full setup, including the
static-credentials fallback. Note that the reconciler rejects setting
`credentialsType: role-based` and `storageSecretRef` at the same time.

---

### Route returns 503 although the pod is healthy

**Cause:** the Route's `spec.port.targetPort` must be the **name** of the service's port, not
its number, when the service uses named ports. `kps-grafana` exposes port 80 named
`http-web`; a Route pointing at `80` matches nothing and the router answers 503 while the pod
sits there perfectly healthy.

```bash
kubectl get svc kps-grafana -n monitoring \
  -o jsonpath='{range .spec.ports[*]}name={.name} port={.port}{"\n"}{end}'
```

**Fix:** use the port name (`targetPort: http-web`).

---

### Probing a distroless container: the command fails and you read it as a result

Not a cluster fault, but it cost real time here. The Prometheus image
(`v3.14.0-distroless`) ships no shell, no `wget` and no `curl`:

```
$ kubectl exec ... -c prometheus -- wget -qO- http://localhost:9090/api/v1/targets
executable file `wget` not found in $PATH
```

If stderr is discarded and the output is piped into a parser, that failure looks exactly like
an empty result — "0 active targets" — and sends you chasing a scraping bug that does not
exist. Query through a port-forward instead:

```bash
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/targets?state=active'
```

---

### "cannot set blockOwnerDeletion if an ownerReference refers to a resource you can't set finalizers on"

**This is the highest-value OpenShift gotcha in this repo.** It broke Prometheus and Reaper
simultaneously, by two different routes, and neither symptom named the cause.

**Why it happens on OpenShift and not on EKS.** OpenShift enables the
`OwnerReferencesPermissionEnforcement` admission plugin, which vanilla Kubernetes leaves off.
Under it, creating a resource whose `ownerReference` sets `blockOwnerDeletion: true` requires
the creator to hold **`update`** on the *owner's* `finalizers` subresource. Both Helm charts
here grant only **`patch`**:

```
["monitoring.coreos.com"] | ["prometheuses","prometheuses/finalizers",...] | ["patch"]
```

That is sufficient on EKS and insufficient here.

**Symptom 1 — Prometheus never gets a StatefulSet.** The `Prometheus` CR exists and looks
fine at a glance:

```bash
kubectl get prometheus -n monitoring -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} msg={.message}{"\n"}{end}'
# Available=False  reason=StatefulSetNotFound
# Reconciled=False reason=ReconciliationFailed
#   msg=synchronizing PrometheusRules failed: ... configmaps "...-rulefiles-0" is forbidden:
#       cannot set blockOwnerDeletion ...
```

**Symptom 2 — Reaper is never created at all,** with no Reaper-specific error anywhere. The
k8ssandra-operator reconcile runs Reaper secrets and schema successfully, then reaches
telemetry and aborts:

```
INFO  Reaper user secrets successfully reconciled
INFO  Reconciling Reaper schema
INFO  Reconciling Stargate and Reaper for dc dc1
ERROR could not create ServiceMonitor resource ... cannot set blockOwnerDeletion ...
```

Everything after that ServiceMonitor call is skipped, so `kubectl get reaper` returns
nothing and it looks like the `reaper:` block was ignored.

**Diagnosing it — use the right syntax.** `kubectl auth can-i` with the `resource/finalizers`
slash form reports the **wrong answer**. Always use `--subresource`:

```bash
# Wrong — says "no" even when permission exists, and "yes" when it does not
kubectl auth can-i update prometheuses/finalizers --as=<sa>

# Right
kubectl auth can-i update prometheuses.monitoring.coreos.com \
  --subresource=finalizers --as=system:serviceaccount:monitoring:kps-kube-prometheus-stack-operator
kubectl auth can-i update cassandradatacenters.cassandra.datastax.com \
  --subresource=finalizers --as=system:serviceaccount:default:k8ssandra-operator
```

**Fix:** apply `manifests/openshift/rbac-finalizers.yaml`, which grants `update` alongside
the charts' `patch`, then restart both operators. `scripts/deploy-openshift.sh` does this
automatically. No chart fork is needed.

---

### One rack keeps failing after you fixed the config in the CR

**Symptom:** you corrected `spec.cassandra.config` and re-applied. Some racks come up on the
new config; one rack keeps restarting with the *old* error, long after the fix was applied.

**Cause:** cass-operator rolls configuration **one rack at a time**, and will not advance to a
rack that is unhealthy. A rack whose Cassandra cannot start is therefore deadlocked — it
cannot receive the fix because it is broken, and it is broken because it lacks the fix.

**Confirm it** by reading the config the operator actually rendered into each rack's
StatefulSet, rather than trusting the CR:

```bash
for r in rack1 rack2 rack3; do
  echo "--- $r ---"
  kubectl get statefulset demo-dc1-$r-sts -n default \
    -o jsonpath='{range .spec.template.spec.initContainers[?(@.name=="server-config-init")]}{.env[?(@.name=="CONFIG_FILE_DATA")].value}{end}' \
    | python3 -m json.tool | grep -A2 cassandra-yaml
done
```

A rack still showing the old keys is stuck.

**Fix:** delete that rack's StatefulSet. cass-operator recreates it from the current
CassandraDatacenter spec, and the PVC is retained, so a node that had already joined keeps
its data:

```bash
kubectl delete statefulset demo-dc1-rack2-sts -n default
```

Deleting the *pod* is not enough — the pod is recreated from the StatefulSet template, which
is what still holds the stale config.

---

### Config changes in the CR never reach the nodes, with no visible error

**Symptom:** you edit `spec.cassandra.datacenters[].config.cassandraYaml`, apply, and the
K8ssandraCluster happily stores your change — but the nodes keep running the old value.
`kubectl get k8ssandracluster demo -o jsonpath='{.spec...cassandraYaml}'` shows the new
setting; the rendered `/etc/cassandra/cassandra.yaml` on the pod does not. No pod restarts,
no obvious complaint.

**This is easy to misdiagnose.** The natural conclusion is that something is filtering
unknown keys. It is not: `cassandraYaml` is `unstructured.Unstructured` with
`PreserveUnknownFields`, so arbitrary keys do pass through.

**Real cause:** some *other* field in the same CR is immutable, the validating webhook
rejects the **entire** CassandraDatacenter write, and every change in that apply is lost
together. The one that bites here is storage:

```
admission webhook "vcassandradatacenter.kb.io" denied the request:
CassandraDatacenter write rejected, attempted to change
storageConfig.CassandraDataVolumeClaimSpec, diff: 50Gi -> 150Gi
```

**Always check the parent's status.error** — this is where webhook rejections surface, and
it is the single most useful command when a CR change appears to do nothing:

```bash
kubectl get k8ssandracluster demo -n default -o jsonpath='{.status.error}'
```

Note the CassandraDatacenter itself will still report `Ready=True` and `Valid=True`, because
the *existing* datacenter is perfectly healthy. Only the update was refused.

**How you get into this state:** expanding PVCs directly with `kubectl patch pvc` (which is
what you do to recover from a full disk) changes the real volumes but not the
CassandraDatacenter. The CR and the datacenter then disagree, and every subsequent apply is
rejected on that diff.

**Fix:** allow the storage change explicitly, on the datacenter metadata:

```yaml
    datacenters:
      - metadata:
          name: dc1
          annotations:
            cassandra.datastax.com/allow-storage-changes: "true"
```

The related annotation `cassandra.datastax.com/autoupdate-spec` (`once` or `always`) forces
StatefulSet spec updates when the CassandraDatacenter itself has not changed.

---

### Cassandra container starts, then dies; readiness probe returns 500 forever

**Symptom:** the pod reaches 2/3 Running, the management API answers liveness but returns
`500` on `/api/v0/probes/readiness` indefinitely, and cass-operator logs
`Deleting stuck pod ... Reason: Pod got stuck after Cassandra container terminated`.

**Where to look.** Not the `cassandra` container — that log is the management API wrapper and
shows only probe traffic. Cassandra's own log is tailed by the sidecar:

```bash
kubectl logs <pod> -c server-system-logger --tail=300 | grep -iE 'error|exception|fatal'
```

**One cause seen here — Cassandra 5.0 renamed settings:**

```
ConfigurationException: Config contains both old and new keys for the same configuration
parameters, migrate old -> new: [key_cache_size_in_mb -> key_cache_size],
[compaction_throughput_mb_per_sec -> compaction_throughput]
```

Cassandra 5.0 refuses to start when both spellings of a setting are present. The operator's
own generated config already uses the **new** names, so adding an old name in
`spec.cassandra.config.cassandraYaml` guarantees a collision — even though the old name is
what most tuning guides, and the `/optimize` skill output, still say.

**Fix:** use the new names, with units.

| Old (do not use) | New |
|---|---|
| `key_cache_size_in_mb: 200` | `key_cache_size: 200MiB` |
| `compaction_throughput_mb_per_sec: 32` | `compaction_throughput: 32MiB/s` |
| `stream_throughput_outbound_megabits_per_sec: 800` | `stream_throughput_outbound: 100MiB/s` |

This affects every profile in this repo, not just OpenShift — the Cassandra version is the
same 5.0.8 everywhere.

---

### CassandraDatacenter rejected: "multiple nodes per worker without cpu and memory requests and limits"

**Symptom:** the K8ssandraCluster is created but no CassandraDatacenter, StatefulSets, pods or
PVCs ever appear. `kubectl get k8ssandracluster` shows the rejection in an ERROR column, and
the operator logs `Failed to create datacenter` on a loop.

```bash
kubectl get k8ssandracluster demo -n default -o jsonpath='{.status.error}'
```

**Cause:** with `softPodAntiAffinity: true`, cass-operator's validating webhook requires
**both** requests *and* limits for **both** cpu *and* memory. Omitting the CPU limit — which
is the documented fix for the CFS throttling that capped an earlier run at 6.0/6.0 CPU — is
therefore incompatible with co-locating Cassandra pods on a node.

The two settings are mutually exclusive. Pick one:

| Goal | Setting |
|---|---|
| One pod per node (enough workers) | No CPU limit. Best for throughput |
| More pods than workers (scale demo on a small cluster) | `softPodAntiAffinity: true` **and** a CPU limit |

**Fix, if you need the co-location:** set a limit high enough that it never binds. The
OpenShift profile requests 12 and limits 14, two pods to a 31.5-CPU worker — the quota exists
to satisfy the webhook, but Cassandra is not expected to reach it. Throttling only hurts when
the quota is actually hit.

Verify at rehearsal that it is not being hit:

```bash
kubectl exec <cassandra-pod> -c cassandra -- \
  cat /sys/fs/cgroup/cpu.stat | grep throttled
```

Non-zero and climbing under load means the limit is binding — raise it, or drop
`softPodAntiAffinity` and accept the smaller ring.

**A note on why this diagnosis is easy to miss:** a webhook rejection means the
CassandraDatacenter is never created, so `kubectl describe cassandradatacenter dc1` returns
NotFound and tells you nothing. The reason lives on the *parent* K8ssandraCluster's
`status.error`. `scripts/deploy-openshift.sh` now prints it on failure.

---

## OpenShift Issues

The OpenShift profile (`manifests/openshift/`) targets an IBM TechZone cluster. These are
the platform differences that actually bite.

### `type: LoadBalancer` service never gets an EXTERNAL-IP

**Cause:** the cluster has no cloud load-balancer integration. This is not a transient
condition — ODF's own `s3` and `sts` services in `openshift-storage` have been `<pending>`
since the cluster was built.

**Fix:** expose through an OpenShift Route instead. See `manifests/openshift/routes.yaml`.
A Route with edge TLS is strictly better for MCP anyway: the endpoint is real https, so
`mcp-remote` no longer needs `--allow-http`.

### Cassandra bootstrap stalls, and there are no AZs to put racks in

**Cause:** this cluster has no `topology.kubernetes.io/zone` labels on any node, so the
rack-per-AZ layout the EKS profile uses cannot be expressed.

**Fix:** racks in Cassandra are a *logical* failure domain — they do not have to be AZs.
`manifests/openshift/node-labels.sh` applies a synthetic `k8ssandra.io/rack` label to three
workers and the CR's `nodeAffinityLabels` targets that instead. What matters is that there
are three: the default `allocate_tokens_for_local_replication_factor=3` cannot allocate
tokens with fewer, and the symptom is a stall rather than an error.

Verify before deploying:

```bash
kubectl get nodes -L workload,k8ssandra.io/rack
```

### `helm install kube-prometheus-stack` fails on existing CRDs

**Cause:** the `monitoring.coreos.com` CRDs are installed and owned by OpenShift's
cluster-version-operator as part of `openshift-monitoring`.

**Fix:** install with `--skip-crds` (this is what `scripts/deploy-openshift.sh` does) and use
the platform's CRDs. Note the version gap — OpenShift ships prometheus-operator 0.81.0 CRDs
while chart 91.4.0 bundles 0.94.0. The chart's `Prometheus` CR was verified to validate
against the older CRDs, but re-check after any chart bump:

```bash
helm template kps prometheus-community/kube-prometheus-stack --version <ver> \
  --namespace monitoring --skip-crds -f manifests/openshift/values-kube-prometheus-stack.yaml \
  | kubectl apply --dry-run=server -f -
```

### Two Prometheus operators reconciling the same objects

**Cause:** OpenShift's operator is scoped to `openshift-monitoring` and
`openshift-user-workload-monitoring`. Ours is scoped to `default` and `monitoring`. That
separation holds **only while user-workload monitoring is disabled**. Enabling UWM makes its
operator start watching ServiceMonitors in `default` too, and the two will fight.

**Fix:** leave UWM off, or drop kube-prometheus-stack's Prometheus and point Grafana at
OpenShift's Thanos querier instead.

### Pod rejected: "unable to validate against any security context constraint"

**Cause:** something pinned a `runAsUser` that `restricted-v2` will not admit. Pods get
arbitrary UIDs from the namespace's range (`openshift.io/sa.scc.uid-range`, e.g.
`1000000000/10000`); Grafana's chart default of 472 and Prometheus's 1000 both fail.

**Fix:** null the UID out so the namespace range applies — this is what
`manifests/openshift/values-kube-prometheus-stack.yaml` does for Grafana and Prometheus,
which run in `monitoring`.

**Why the Cassandra pods do not need this, and why that is fragile.** They run in `default`,
and OpenShift labels `default` with `pod-security.kubernetes.io/enforce: privileged` — it is
exempt from Pod Security Admission. Observed on this cluster:

```bash
$ kubectl get pod demo-dc1-rack1-sts-0 -o jsonpath='{.spec.securityContext}'
{"fsGroup":999,"runAsGroup":999,"runAsNonRoot":true,"runAsUser":999}

$ kubectl get ns default -o jsonpath='{.metadata.labels}'
... "pod-security.kubernetes.io/enforce":"privileged" ...
```

UID 999 is cass-operator's own value. It is **not** from the namespace's
`openshift.io/sa.scc.uid-range` (`1000000000/10000`), and it was not stripped despite
cass-operator's `openshift.mode: auto`. The pods are admitted because the namespace is
exempt, not because the security context was adjusted.

**The consequence:** moving this workshop into a dedicated project (`oc new-project k8ssandra`)
would subject it to PSA `restricted` and very likely break Cassandra startup. If you do move
it, expect to grant an SCC:

```bash
oc adm policy add-scc-to-user anyuid -z default -n <namespace>
```

Last resort, per ServiceAccount:

```bash
oc adm policy add-scc-to-user anyuid -z <serviceaccount> -n <namespace>
```

### Medusa cannot reach the NooBaa bucket

**Cause:** NooBaa speaks S3 but is not AWS, so `storageProvider` must be `s3_compatible`
with an explicit `host`/`port` rather than `s3` with a region. Its in-cluster endpoint also
presents a self-signed certificate.

**Fix:** the CR sets `host: s3.openshift-storage.svc.cluster.local`, `port: 443`,
`secure: true`, `sslVerify: false`. Traffic never leaves the cluster network.

Note the credential shape mismatch: an ObjectBucketClaim produces a Secret with
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, but Medusa wants a single `credentials` key in
INI format. `scripts/deploy-openshift.sh` translates between them — if you create the bucket
by hand, you must do the same.

---

## Cassandra Driver Issues

### "Connection refused" or timeout when connecting from local machine
**Cause**: The Cassandra Python driver discovers all node IPs during handshake and tries to connect directly to pod IPs (10.0.x.x), which aren't reachable from outside the cluster.
**Fix**: Run easy-cass-mcp as an in-cluster deployment instead of locally. Or for local development, use `WhiteListRoundRobinPolicy(['localhost'])` and a single-node cluster.

## easy-cass-mcp Issues

### MCP server binds to 127.0.0.1 — NLB can't reach it
**Cause**: FastMCP defaults to `127.0.0.1`.
**Fix**: Set `FASTMCP_SERVER_HOST=0.0.0.0` in the deployment env vars. Note: `UVICORN_HOST` and `HOST` env vars do NOT work.

### Claude Desktop can't connect to remote MCP server
**Cause**: Claude Desktop doesn't support `"type": "streamable-http"` in config files.
**Fix**: Use `npx mcp-remote` as a stdio bridge:
```json
{
  "mcpServers": {
    "cassandra": {
      "command": "npx",
      "args": ["mcp-remote", "http://<NLB_HOST>:8000/mcp/", "--allow-http"]
    }
  }
}
```

### mcp-remote fails with "Non-HTTPS URLs are only allowed for localhost"
**Fix**: Add `--allow-http` flag to the args.

### Claude Desktop "Failed to spawn process: No such file or directory"
**Cause**: `npx`, `uv`, `kubectl`, or `aws` not in Claude Desktop's PATH.
**Fix**: Symlink to `/usr/local/bin`:
```bash
sudo ln -sf $(which npx) /usr/local/bin/npx
sudo ln -sf $(which kubectl) /usr/local/bin/kubectl
sudo ln -sf $(which aws) /usr/local/bin/aws
```

## NoSQLBench Issues

### "Unable to load path 'cql-keyvalue'"
**Cause**: The Docker image doesn't bundle the `cql-keyvalue` workload.
**Fix**: Use a custom workload YAML via ConfigMap (see `manifests/loadtest/`).

### "nb5: not found"
**Cause**: The Docker image entrypoint is `nb5` but when overriding with `/bin/sh`, it's not in PATH.
**Fix**: Use `java -jar /nb5.jar` to invoke NoSQLBench.

### Binding parse errors with `<<template>>` syntax
**Cause**: Template variable syntax not supported in this NB5 version.
**Fix**: Hardcode values directly in the workload YAML instead of using `<<var:default>>`.

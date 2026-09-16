# K8ssandra on OpenShift - Architecture Diagrams

Companion to `architecture-diagrams.md`, which describes the EKS profile. This one
describes the **live cluster the workshop actually runs on**: IBM TechZone OpenShift
4.19.38 / Kubernetes 1.32.13, cluster `itz-ckzpiv`, Dallas.

Everything here was read off the running cluster, not idealised.

---

## 1. Infrastructure Topology

```
+==============================================================================+
||  IBM TechZone - OpenShift 4.19.38 (Kubernetes 1.32.13)                     ||
||  API:     https://api.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com:6443    ||
||  Ingress: *.apps.itz-ckzpiv.infra01-lb.dal14.techzone.ibm.com              ||
+==============================================================================+

  Control plane                        NOT schedulable
  +----------------------+  +----------------------+  +----------------------+
  | itz-ckzpiv-master-1  |  | itz-ckzpiv-master-2  |  | itz-ckzpiv-master-3  |
  | 8 vCPU / 32 GiB      |  | 8 vCPU / 32 GiB      |  | 8 vCPU / 32 GiB      |
  | taint: node-role.    |  | taint: node-role.    |  | taint: node-role.    |
  |   kubernetes.io/     |  |   kubernetes.io/     |  |   kubernetes.io/     |
  |   master             |  |   master             |  |   master             |
  +----------------------+  +----------------------+  +----------------------+

  Workers - 5 x 32 vCPU / 125 GiB  (31.5 CPU / ~124 GiB allocatable each)

  +----------------------+  +----------------------+  +----------------------+
  | worker-1             |  | worker-2             |  | worker-3             |
  | workload=cassandra   |  | workload=cassandra   |  | workload=cassandra   |
  | k8ssandra.io/rack=   |  | k8ssandra.io/rack=   |  | k8ssandra.io/rack=   |
  |   rack1              |  |   rack2              |  |   rack3              |
  +----------------------+  +----------------------+  +----------------------+

  +----------------------+  +----------------------+
  | worker-4             |  | worker-5             |
  | workload=loadgen     |  | workload=utility     |
  | TAINT                |  | (no taint)           |
  |  workload=loadgen    |  |                      |
  |  :NoSchedule         |  |                      |
  +----------------------+  +----------------------+

  !! NO topology.kubernetes.io/zone LABELS EXIST ON THIS CLUSTER !!
     Every node is in one datacenter. Rack-per-AZ - the EKS design - cannot be
     expressed. Racks map to NODES via a synthetic k8ssandra.io/rack label
     applied by manifests/openshift/node-labels.sh.

     Three racks is the part that matters: Cassandra's default
     allocate_tokens_for_local_replication_factor=3 cannot allocate tokens with
     fewer, and the failure mode is a silent bootstrap stall, not an error.

  Storage                                    Object storage
  +-----------------------------------+      +------------------------------+
  | OpenShift Data Foundation (ODF)   |      | NooBaa (Multicloud Gateway)  |
  | CephCluster: ocs-external-        |      | S3-compatible, in-cluster    |
  |   storagecluster-cephcluster      |      | svc: s3.openshift-storage    |
  | HEALTH_OK, EXTERNAL Ceph          |      |      .svc:443                |
  |                                   |      | Backs Medusa via an          |
  | SC: ocs-storagecluster-ceph-rbd   |      |   ObjectBucketClaim          |
  |     (default, RWO, Immediate)     |      | No AWS account, no IAM       |
  +-----------------------------------+      +------------------------------+

  !! LoadBalancer SERVICES NEVER PROVISION HERE !!
     There is no cloud LB integration. ODF's own s3 and sts Services have sat
     <pending> since the cluster was built. All external access is by Route.
```

---

## 2. Namespace & Workload Layout

Actual pod placement, as scheduled:

```
Namespace: default                    (PSA enforce=privileged - see section 4)
+------------------------------------------------------------------------------+
|                                                                              |
|  Cassandra ring - one StatefulSet PER RACK, not one per datacenter           |
|  +---------------------+ +---------------------+ +---------------------+     |
|  | demo-dc1-rack1-sts  | | demo-dc1-rack2-sts  | | demo-dc1-rack3-sts  |     |
|  | -0     [worker-1]   | | -0     [worker-2]   | | -0     [worker-3]   |     |
|  |                     | |                     | |                     |     |
|  | init containers:    | | init:  (same)       | | init:  (same)       |     |
|  |  server-config-     | |                     | |                     |     |
|  |    init-base        | |                     | |                     |     |
|  |  server-config-init | |                     | |                     |     |
|  |  medusa-restore     | |                     | |                     |     |
|  |                     | |                     | |                     |     |
|  | containers 3/3:     | | containers 3/3      | | containers 3/3      |     |
|  |  cassandra   (5.0.8)| |                     | |                     |     |
|  |  medusa      sidecar| |                     | |                     |     |
|  |  server-system-     | |                     | |                     |     |
|  |    logger           | |                     | |                     |     |
|  |                     | |                     | |                     |     |
|  | cpu req 12 / lim 14 | | (same)              | | (same)              |     |
|  | mem 32Gi, heap 8G   | |                     | |                     |     |
|  | PVC 50Gi ceph-rbd   | |                     | |                     |     |
|  +---------------------+ +---------------------+ +---------------------+     |
|   softPodAntiAffinity: true  -> 2 pods/node once the ring scales 3 -> 6      |
|                                                                              |
|  Operators                              Reaper                               |
|  +----------------------------+         +----------------------------+       |
|  | k8ssandra-operator         |         | demo-dc1-reaper            |       |
|  |   [worker-5]               |         |   [worker-5]               |       |
|  | cass-operator              |         | storageType: cassandra     |       |
|  |   [worker-2]  <- lands on  |         |   (schedules in reaper_db, |       |
|  |   a Cassandra node; the    |         |    no PVC of its own)      |       |
|  |   operators are not        |         | autoScheduling: false      |       |
|  |   nodeSelected             |         +----------------------------+       |
|  +----------------------------+                                              |
|                                                                              |
|  MCP server                             Load generator                       |
|  +----------------------------+         +----------------------------+       |
|  | easy-cass-mcp  [worker-5]  |         | nosqlbench-*   [worker-4]  |       |
|  | ClusterIP :8000            |         | nodeSelector workload=     |       |
|  | FASTMCP_SERVER_HOST=       |         |   loadgen + toleration     |       |
|  |   0.0.0.0                  |         | prepare job: schema + 20M  |       |
|  | creds: demo-superuser      |         | load job:    50/50 rw      |       |
|  +----------------------------+         +----------------------------+       |
|                                                                              |
|  Services (all ClusterIP - no LoadBalancer on this cluster)                  |
|    demo-dc1-service                 9042 9142 8080 9103 9000                 |
|    demo-dc1-all-pods-service        9042 8080 9103 9000   <- NB + MCP target |
|    demo-dc1-contact-points-service  9000 9103 8080 9042                      |
|    demo-seed-service / demo-dc1-additional-seed-service   (headless)         |
|    demo-dc1-reaper-service          8080 8081                                |
|    easy-cass-mcp                    8000                                     |
+------------------------------------------------------------------------------+

Namespace: monitoring                 (PSA NOT privileged - UIDs are assigned)
+------------------------------------------------------------------------------+
|  kube-prometheus-stack, release "kps", installed with --skip-crds            |
|                                                                              |
|  +----------------------------+  +----------------------------+              |
|  | prometheus-kps-...-0       |  | kps-grafana  [worker-5]    |              |
|  |   [worker-5]               |  | 3 containers:              |              |
|  | 20Gi PVC on ceph-rbd       |  |   grafana                  |              |
|  | retention 12h              |  |   grafana-sc-dashboard     |              |
|  | scrapes ServiceMonitors in |  |   grafana-sc-datasources   |              |
|  |   default + monitoring     |  | ClusterIP :80 (http-web)   |              |
|  +----------------------------+  +----------------------------+              |
|  | kps-kube-prometheus-stack-operator  [worker-5]             |              |
|  +------------------------------------------------------------+              |
|                                                                              |
|  ServiceMonitors written BY the k8ssandra-operator, into `default`:          |
|    demo-dc1-cass-servicemonitor            (mgmt-api :9000)                  |
|    demo-dc1-reaper-reaper-servicemonitor                                     |
|  Both carry label release=kps so this Prometheus selects them.               |
+------------------------------------------------------------------------------+

Platform namespaces we depend on but do not own
+------------------------------------------------------------------------------+
|  openshift-monitoring   thanos-querier:9091  <- Grafana's 2nd datasource     |
|                         (cAdvisor + node metrics; our stack does not         |
|                          scrape the kubelet)                                 |
|  openshift-storage      NooBaa s3:443, ODF Ceph CSI                          |
|  openshift-ingress      the router that serves every Route below             |
+------------------------------------------------------------------------------+
```

---

## 3. Data Flow: Claude Code to Cassandra

```
  Developer laptop
  +--------------------------------------+
  | Claude Code / Claude Desktop         |
  |   npx mcp-remote                     |
  |     https://easy-cass-mcp-default    |
  |       .apps.itz-ckzpiv...../mcp/     |
  |                                      |
  |   NOTE: no --allow-http. The Route   |
  |   terminates TLS at the edge, so     |
  |   this is real https - unlike the    |
  |   EKS profile's plain-HTTP NLB.      |
  +------------------+-------------------+
                     | HTTPS
                     v
  +--------------------------------------+
  | OpenShift Router (openshift-ingress)  |
  | Route: easy-cass-mcp, termination=edge|
  +------------------+-------------------+
                     | HTTP :8000 (in-cluster)
                     v
  +--------------------------------------+
  | Service easy-cass-mcp (ClusterIP)     |
  +------------------+-------------------+
                     v
  +--------------------------------------+
  | Pod easy-cass-mcp        [worker-5]   |
  | Python driver, CQL                    |
  +------------------+-------------------+
                     | CQL :9042
                     v
  +--------------------------------------+
  | Service demo-dc1-all-pods-service      |
  +---+--------------+---------------+-----+
      |              |               |
      v              v               v
  rack1-sts-0    rack2-sts-0     rack3-sts-0
  [worker-1]     [worker-2]      [worker-3]

  The driver discovers pod IPs and connects to them directly, which is why the
  MCP server must run IN-cluster. From a laptop those 10.x addresses are
  unroutable and the driver hangs rather than failing cleanly.

  Other Routes (same router, all edge TLS):
    reaper   -> demo-dc1-reaper-service:8080   /webui/index.html
    grafana  -> kps-grafana:http-web           (port NAME, not 80 - see sec. 4)
```

---

## 4. What OpenShift Changes (and the traps)

```
+------------------------------------------------------------------------------+
|  ADMISSION                                                                   |
|                                                                              |
|  OwnerReferencesPermissionEnforcement  -- ENABLED on OpenShift, off on       |
|                                           vanilla Kubernetes                 |
|                                                                              |
|    Creating X with ownerReference{blockOwnerDeletion: true} pointing at Y    |
|    requires UPDATE on Y/finalizers. Both Helm charts grant only `patch`.     |
|                                                                              |
|    Broke two things by different routes, neither naming the cause:           |
|      kps operator    -> Prometheus CR created, StatefulSet never appeared    |
|      k8ssandra-op    -> ServiceMonitor refused; reconcile ABORTED there,     |
|                         so Reaper was never created and looked "ignored"     |
|    Fix: manifests/openshift/rbac-finalizers.yaml                             |
|                                                                              |
|  Pod Security Admission                                                      |
|    ns/default     enforce=privileged   <- OpenShift exempts `default`        |
|    ns/monitoring  not privileged                                             |
|                                                                              |
|    Cassandra pods run as runAsUser=999 (cass-operator's own value, NOT       |
|    stripped, NOT from the namespace's 1000000000/10000 range). They are      |
|    admitted because `default` is exempt - so the namespace choice is         |
|    LOAD-BEARING. Grafana/Prometheus live in `monitoring` and therefore have  |
|    every hardcoded runAsUser nulled out in the Helm values.                  |
+------------------------------------------------------------------------------+

+------------------------------------------------------------------------------+
|  CRDs                                                                        |
|    monitoring.coreos.com/*   owned by the CLUSTER-VERSION-OPERATOR           |
|                              (prometheus-operator 0.81.0)                    |
|      -> kube-prometheus-stack MUST install with --skip-crds                  |
|      -> chart 91.4.0 bundles operator 0.94.0; its Prometheus CR was verified |
|         to validate against the older platform CRDs. Re-check on any bump.   |
|                                                                              |
|    k8ssandra.io / cassandra.datastax.com / medusa.k8ssandra.io /             |
|    reaper.k8ssandra.io / objectbucket.io   - installed by us / by ODF        |
|                                                                              |
|    route.openshift.io and security.openshift.io are AGGREGATED APIs, not     |
|    CRDs. `kubectl get crd routes.route.openshift.io` returns NotFound on a   |
|    perfectly healthy cluster - probe the API group instead.                  |
+------------------------------------------------------------------------------+

+------------------------------------------------------------------------------+
|  ROUTES                                                                      |
|    spec.port.targetPort must be the service's port NAME when the service     |
|    uses named ports. kps-grafana exposes 80 named "http-web"; a Route        |
|    pointing at `80` matches nothing and the router answers 503 while the pod |
|    is perfectly healthy.                                                     |
+------------------------------------------------------------------------------+
```

### EKS -> OpenShift, side by side

| | EKS profile | OpenShift profile |
|---|---|---|
| Racks | `topology.kubernetes.io/zone` (3 AZs) | `k8ssandra.io/rack` (3 nodes) |
| Node config | eksctl ClusterConfig, declarative | `node-labels.sh`, imperative |
| Storage | EBS gp3, 6000 IOPS / 500 MB/s | Ceph RBD (ODF), no perf knobs |
| PVC size | 60Gi | 50Gi |
| Backups | AWS S3 + IRSA role | NooBaa OBC, in-cluster, no IAM |
| MCP exposure | internet-facing NLB, plain HTTP | Route, edge TLS |
| Metrics API | metrics-server installed | built in (`metrics.k8s.io`) |
| Monitoring CRDs | installed by the chart | owned by the platform (`--skip-crds`) |
| Pod CPU metrics | same Prometheus | 2nd datasource (OpenShift Thanos) |
| Anti-affinity | hard, 1 pod/node | soft, 1-2 pods/node |
| CPU limit | none (avoids CFS throttling) | 14, **deliberately binding** |

---

## 5. Deployment Pipeline (deploy-openshift.sh)

```
  manifests/openshift/node-labels.sh        <- run FIRST, out of band
    labels 3 workers rack1/2/3, taints the loadgen node
         |
         v
  ./scripts/deploy-openshift.sh
         |
  [1] Preflight  -- probes route.openshift.io + security.openshift.io API
         |          groups (NOT CRDs); asserts 3 distinct rack labels;
         |          asserts the ceph-rbd StorageClass exists.
         |          HARD STOPS rather than failing 20 minutes later.
         v
  [2] StorageClass check                      (ODF provides it; nothing applied)
         |
  [3] cert-manager  v1.21.2                   -> ns cert-manager
         |          (metrics-server step from the EKS script is OMITTED)
         v
  [4] kube-prometheus-stack 91.4.0 --skip-crds -> ns monitoring, release "kps"
         |    + rbac-finalizers.yaml           <- without this, no Prometheus
         |    + Thanos datasource Secret        <- token minted here, not committed
         |    + grafana-dashboard-cassandra
         v
  [5] k8ssandra-operator 1.33.0                -> ns default
         |    (cass-operator openshift.mode=auto)
         v
  [6] ObjectBucketClaim medusa-backups         -> NooBaa provisions a bucket
         |    OBC emits  AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
         |    Medusa wants  [default]\naws_access_key_id = ...
         |    -> the script TRANSLATES into secret medusa-bucket-key
         v
  [7] K8ssandraCluster (bucket name substituted at render time)
         |    waits on CassandraDatacenter/dc1 Ready, up to 2400s
         |    30s ticker prints pod/rack/ready so a long wait is not a hang
         |    asserts rack balance afterwards
         v
  [8] easy-cass-mcp + NoSQLBench ConfigMap + Routes
         |    rollout restart of easy-cass-mcp (known "Bad credentials" race)
         v
  [9] Summary: Route URLs, superuser creds, bucket name; rewrites .mcp.json
              Exits NON-ZERO if the datacenter never became Ready.

  Load testing is deliberately NOT part of deploy:
    kubectl apply -f manifests/loadtest/nosqlbench-prepare-job.yaml   (once)
    kubectl apply -f manifests/loadtest/nosqlbench-job.yaml           (sustained)
```

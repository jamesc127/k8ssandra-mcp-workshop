# K8ssandra on EKS - Architecture Diagrams

## 1. AWS / EKS Infrastructure Topology

```
+-----------------------------------------------------------------------------------+
|  AWS Region: us-east-1                                                            |
|                                                                                   |
|  +-----------------------------------------------------------------------------+ |
|  |  VPC (eksctl-managed)                                                        | |
|  |                                                                              | |
|  |  Public Subnets (tagged: kubernetes.io/role/elb=1)                           | |
|  |  +----------------------------------+                                        | |
|  |  |  Internet-Facing NLB             |                                        | |
|  |  |  a2838...us-east-1.elb.aws.com   |<---------- Internet / Claude Desktop   | |
|  |  |  Port 8000 (TCP)                 |                                        | |
|  |  +-----------------|----------------+                                        | |
|  |                    |                                                          | |
|  |  Private Subnets (tagged: kubernetes.io/role/internal-elb=1)                  | |
|  |  +------------------------------------------------------------------------+  | |
|  |  |  EKS Cluster: k8ssandra-cluster  (K8s 1.31)                            |  | |
|  |  |  OIDC Provider enabled (for IRSA)                                      |  | |
|  |  |                                                                        |  | |
|  |  |  Managed Node Group: cassandra-workers                                 |  | |
|  |  |  +------------------------+  +------------------------+  +-----------+ |  | |
|  |  |  | m5.xlarge              |  | m5.xlarge              |  | m5.xlarge | |  | |
|  |  |  | 4 vCPU / 16 GiB       |  | 4 vCPU / 16 GiB       |  | 4 vCPU /  | |  | |
|  |  |  | 50 GiB gp3 root       |  | 50 GiB gp3 root       |  | 16 GiB    | |  | |
|  |  |  | ip-192-168-118-142     |  | ip-192-168-65-41       |  | 50 GiB gp3| |  | |
|  |  |  | privateNetworking:true |  | privateNetworking:true |  | ip-192-168| |  | |
|  |  |  +------------------------+  +------------------------+  | -97-216   | |  | |
|  |  |                                                           +-----------+ |  | |
|  |  |  EBS Volumes (gp3, dynamic provisioning via CSI)                       |  | |
|  |  |  +----------------+  +----------------+  +----------------+            |  | |
|  |  |  | PVC: 5Gi RWO   |  | PVC: 5Gi RWO   |  | PVC: 5Gi RWO   |           |  | |
|  |  |  | server-data-0  |  | server-data-1  |  | server-data-2  |            |  | |
|  |  |  +----------------+  +----------------+  +----------------+            |  | |
|  |  +------------------------------------------------------------------------+  | |
|  +-----------------------------------------------------------------------------+ |
+-----------------------------------------------------------------------------------+
```

## 2. Kubernetes Namespace & Workload Layout

```
+==============================================================================+
||  EKS Cluster: k8ssandra-cluster                                            ||
+==============================================================================+

Namespace: default
+------------------------------------------------------------------------------+
|                                                                              |
|  Operators                                                                   |
|  +-------------------------------+  +-------------------------------+        |
|  | Deployment                    |  | Deployment                    |        |
|  | k8ssandra-operator            |  | cass-operator                 |        |
|  | (1 replica)                   |  | (1 replica)                   |        |
|  | Watches: K8ssandraCluster CR  |  | Watches: CassandraDatacenter |        |
|  +-------------------------------+  +-------------------------------+        |
|                                                                              |
|  Cassandra Ring (StatefulSet: demo-dc1-default-sts)                          |
|  +---------------------+ +---------------------+ +---------------------+    |
|  | Pod: sts-0           | | Pod: sts-1           | | Pod: sts-2           |   |
|  | Containers: 2/2      | | Containers: 2/2      | | Containers: 2/2      |  |
|  |  - cassandra         | |  - cassandra         | |  - cassandra         |   |
|  |  - server-system-log | |  - server-system-log | |  - server-system-log |   |
|  | PVC: 5Gi ebs-gp3     | | PVC: 5Gi ebs-gp3     | | PVC: 5Gi ebs-gp3     |  |
|  | Port: 9042 (CQL)     | | Port: 9042 (CQL)     | | Port: 9042 (CQL)     |  |
|  +---------------------+ +---------------------+ +---------------------+    |
|                                                                              |
|  MCP Server                                 Load Testing                     |
|  +-------------------------------+          +---------------------------+    |
|  | Deployment: easy-cass-mcp     |          | Job: nosqlbench-load      |    |
|  | (1 replica)                   |          | (Completed)               |    |
|  | Image: rustyrazorblade/       |          | Image: nosqlbench/        |    |
|  |   easy-cass-mcp:latest        |          |   nosqlbench              |    |
|  | Port: 8000 (HTTP/SSE)         |          | ConfigMap-mounted         |    |
|  | Env:                          |          |   workload YAML           |    |
|  |  CASSANDRA_HOST=demo-dc1-     |          | 3 phases:                 |    |
|  |    all-pods-service            |          |   schema / rampup / main  |    |
|  |  FASTMCP_SERVER_HOST=0.0.0.0  |          +---------------------------+    |
|  |  Creds from demo-superuser    |                                           |
|  |    Secret (via secretKeyRef)  |                                           |
|  +-------------------------------+                                           |
|                                                                              |
|  Webhook Services (ClusterIP)                                                |
|  +-------------------------------+  +-------------------------------+        |
|  | k8ssandra-operator-webhook    |  | cass-operator-webhook         |        |
|  | :443                          |  | :443                          |        |
|  +-------------------------------+  +-------------------------------+        |
+------------------------------------------------------------------------------+

Namespace: cert-manager
+------------------------------------------------------------------------------+
|  +--------------------+  +--------------------+  +--------------------+      |
|  | cert-manager       |  | cainjector          |  | webhook            |     |
|  | (1 replica)        |  | (1 replica)        |  | (1 replica)        |      |
|  | Manages TLS certs  |  | Injects CA bundles |  | Validates cert CRs |     |
|  +--------------------+  +--------------------+  +--------------------+      |
+------------------------------------------------------------------------------+

Namespace: kube-system
+------------------------------------------------------------------------------+
|  +--------------------+  +--------------------+  +--------------------+      |
|  | aws-node (x3)      |  | kube-proxy (x3)    |  | coredns (x2)       |     |
|  | VPC CNI DaemonSet  |  | iptables rules     |  | Cluster DNS        |      |
|  +--------------------+  +--------------------+  +--------------------+      |
|  +--------------------+  +--------------------+                              |
|  | ebs-csi-controller |  | ebs-csi-node (x3)  |                             |
|  | (2 replicas)       |  | DaemonSet          |                              |
|  | IRSA-backed        |  | Mounts EBS volumes |                             |
|  +--------------------+  +--------------------+                              |
+------------------------------------------------------------------------------+
```

## 3. Data Flow: Claude Desktop to Cassandra

```
+------------------+       +-------------+       +--------------+
|  Claude Desktop  |       |  npx        |       |  Internet-   |
|  (macOS)         |------>|  mcp-remote |------>|  Facing NLB  |
|                  | stdio |  (stdio     | HTTP  |  Port 8000   |
|  MCP Client      |       |   bridge)   |       |  (TCP)       |
+------------------+       +-------------+       +------|-------+
                                                        |
                                          +-------------|-------------+
                                          | EKS Cluster               |
                                          |             v             |
                                          |  +--------------------+  |
                                          |  | easy-cass-mcp Pod  |  |
                                          |  | Port 8000          |  |
                                          |  | MCP Server (SSE)   |  |
                                          |  +---------+----------+  |
                                          |            |             |
                                          |    CQL (port 9042)      |
                                          |    via Headless Service: |
                                          |    demo-dc1-all-pods-svc |
                                          |            |             |
                                          |    +-------v--------+   |
                                          |    | Cassandra Ring  |   |
                                          |    | sts-0  sts-1    |   |
                                          |    |     sts-2       |   |
                                          |    | RF=3, DC=dc1    |   |
                                          |    +----------------+   |
                                          +-------------------------+
```

## 4. Kubernetes Resource Relationships (CRDs, RBAC, Storage)

```
Custom Resource Definitions (CRDs)
===================================

k8ssandra.io                          cassandra.datastax.com
+---------------------------+         +---------------------------+
| K8ssandraCluster          |-------->| CassandraDatacenter       |
| name: demo                | creates | name: dc1                 |
| spec:                     |         | size: 3                   |
|   cassandra:              |         | serverVersion: 4.1.3      |
|     serverVersion: 4.1.3  |         +---------------------------+
|     datacenters:          |                    |
|       - name: dc1         |                    | manages
|         size: 3           |                    v
+---------------------------+         +---------------------------+
                                      | StatefulSet               |
                                      | demo-dc1-default-sts      |
                                      | replicas: 3               |
                                      +---------------------------+

cert-manager.io
+---------------------------+
| Issuer / ClusterIssuer    |  (webhook TLS)
| Certificate               |
| CertificateRequest        |
+---------------------------+

control.k8ssandra.io                  medusa.k8ssandra.io
+---------------------------+         +---------------------------+
| CassandraTask             |         | MedusaBackup              |
| K8ssandraTask             |         | MedusaBackupJob           |
| ScheduledTask             |         | MedusaBackupSchedule      |
+---------------------------+         | MedusaRestoreJob          |
                                      | MedusaConfiguration       |
reaper.k8ssandra.io                   +---------------------------+
+---------------------------+
| Reaper                    |
+---------------------------+


Storage Chain
===================================

StorageClass          PersistentVolumeClaim       PersistentVolume
+----------------+    +-----------------------+   +------------------+
| ebs-gp3        |    | server-data-sts-0     |   | pvc-0b287...     |
| provisioner:   |<---| 5Gi, RWO              |-->| 5Gi EBS gp3      |
|  ebs.csi.aws.  |    +-----------------------+   +------------------+
|  com           |    | server-data-sts-1     |   | pvc-06b41...     |
| volumeBinding: |<---| 5Gi, RWO              |-->| 5Gi EBS gp3      |
|  WaitForFirst  |    +-----------------------+   +------------------+
|  Consumer      |    | server-data-sts-2     |   | pvc-75d3e...     |
| reclaimPolicy: |<---| 5Gi, RWO              |-->| 5Gi EBS gp3      |
|  Delete        |    +-----------------------+   +------------------+
+----------------+


Secrets
===================================

+---------------------------+         Referenced by:
| Secret: demo-superuser    |         - easy-cass-mcp Deployment (env secretKeyRef)
| (auto-generated by        |         - nosqlbench-load Job (env secretKeyRef)
|  k8ssandra-operator)      |
| Keys: username, password  |
+---------------------------+


Headless Services (ClusterIP: None)
===================================

+-----------------------------------+    Used by:
| demo-dc1-all-pods-service         |    - easy-cass-mcp (CASSANDRA_HOST)
| Ports: 9042, 8080, 9103, 9000    |    - nosqlbench (HOST)
+-----------------------------------+    - Cassandra Python driver pod discovery
| demo-dc1-contact-points-service   |
| demo-dc1-service                  |    Gossip & seed discovery:
| demo-seed-service                 |    - demo-seed-service
| demo-dc1-additional-seed-service  |    - demo-dc1-additional-seed-service
+-----------------------------------+
```

## 5. Deployment Pipeline (deploy.sh)

```
Step 1             Step 2              Step 3               Step 4              Step 5
StorageClass       cert-manager        k8ssandra-operator   K8ssandraCluster    Apps
+----------+       +-------------+     +---------------+    +-------------+     +-------------+
| ebs-gp3  |------>| Helm chart  |---->| Helm chart    |--->| CR: demo    |---->| easy-cass-  |
| SC for   |       | namespace:  |     | namespace:    |    | 3-node ring |     |   mcp       |
| EBS CSI  |       | cert-manager|     | default       |    | dc1, 5Gi    |     | nosqlbench  |
|          |       | CRDs + pods |     | Operators +   |    | 512M heap   |     |   configmap |
|          |       |             |     | webhooks      |    | ~3-5 min    |     | NLB wait    |
+----------+       +-------------+     +---------------+    +-------------+     +-------------+
   instant           ~2 min              ~2 min               ~5 min              ~3 min

                           Total fresh deploy: ~12-15 min (+ EKS cluster: ~15-20 min)
```

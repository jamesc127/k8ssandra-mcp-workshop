# K8ssandra on EKS Workshop

Deploy a production-style Apache Cassandra cluster on Amazon EKS using k8ssandra-operator, then manage it with AI tooling via Claude Desktop and MCP.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  EKS Cluster — 6x m5.4xlarge managed nodes (private subnets)         │
│                                                                       │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐                        │
│  │ Cassandra  │ │ Cassandra  │ │ Cassandra  │  3-pod default,         │
│  │ dc1 / sts-0│ │ dc1 / sts-1│ │ dc1 / sts-2│  scales to 6 live      │
│  │ 2G heap    │ │ 2G heap    │ │ 2G heap    │  via K8ssandraCluster  │
│  │ 5Gi gp3 EBS│ │ 5Gi gp3 EBS│ │ 5Gi gp3 EBS│  size patch            │
│  └────────────┘ └────────────┘ └────────────┘                        │
│                                                                       │
│  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐      │
│  │k8ssandra-operator│ │ cert-manager     │ │ metrics-server   │      │
│  └──────────────────┘ └──────────────────┘ └──────────────────┘      │
│                                                                       │
│  ┌──────────────────┐ ┌──────────────────────────────────────────┐   │
│  │ easy-cass-mcp    │ │ NoSQLBench  (1hr @ 100k ops/sec default) │   │
│  │ (MCP server)     │ │ pod anti-affinity vs Cassandra pods      │   │
│  └──────────────────┘ └──────────────────────────────────────────┘   │
└──────────────┬───────────────────────────────────────────────────────┘
               │ NLB (internet-facing, port 8000)
               ▼
┌──────────────────────┐
│  Claude Desktop       │  ← mcp-remote bridge → easy-cass-mcp
│  + Kubernetes MCP     │  ← API-based cluster management
└──────────────────────┘
```

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Apache Cassandra | 4.1.3 | Distributed database (3-pod ring, scales to 6 live) |
| k8ssandra-operator | 1.26.0 | Cassandra lifecycle management |
| cert-manager | v1.18.2 | TLS certificates for operator webhooks |
| metrics-server | v0.8.0 | `kubectl top` node/pod CPU and memory |
| easy-cass-mcp | latest | MCP server for AI-powered Cassandra ops |
| NoSQLBench | latest | CQL load testing (default 1 hour @ 100k ops/sec) |

## Prerequisites

- AWS CLI configured with appropriate IAM permissions
- `kubectl` installed and configured
- `eksctl` for EKS cluster creation
- Helm 3.x
- Node.js 18+ (for `mcp-remote` bridge)
- Claude Desktop (for MCP integration)

## Quick Start

### 1. Create the EKS Cluster

```bash
eksctl create cluster -f manifests/infra/eksctl-cluster.yaml
```

This takes about 15 minutes. The ClusterConfig creates:
- A VPC with properly tagged public and private subnets
- A managed node group with 6x `m5.4xlarge` nodes in private subnets (sized for 100k TPS load test + 3→6 Cassandra elasticity demo)
- The EBS CSI driver addon (with IAM via IRSA)
- An OIDC provider for service account IAM roles

> **Cost note:** 6× m5.4xlarge runs ≈ $4.60/hr in us-east-1. Tear the cluster down (`eksctl delete cluster ...`) when not actively using it. If you want a cheaper sandbox at the cost of skipping the 100k TPS demo, edit `manifests/infra/eksctl-cluster.yaml` to use smaller instances (e.g., `m5.xlarge × 3`) and dial down `cyclerate` in the NoSQLBench job.

To customize the cluster name or region, edit `manifests/infra/eksctl-cluster.yaml` before running.

### 2. Deploy Everything

```bash
./scripts/deploy.sh
```

The deploy script runs 6 steps in order:
1. StorageClass (`ebs-gp3` with the EBS CSI driver)
2. cert-manager (Helm)
3. metrics-server (Helm, into `kube-system`)
4. k8ssandra-operator (Helm, into `default` namespace)
5. K8ssandraCluster (3-pod Cassandra ring, 2G heap, Burstable QoS)
6. easy-cass-mcp + NoSQLBench (deployment, NLB service, workload ConfigMap)

It waits for all resources to become ready and prints the NLB hostname at the end.

You can customize the cluster name and region:
```bash
CLUSTER_NAME=my-cluster REGION=us-west-2 ./scripts/deploy.sh
```

### 3. Configure Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "cassandra": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "http://<NLB_HOSTNAME>:8000/mcp/",
        "--allow-http"
      ]
    },
    "kubernetes": {
      "command": "npx",
      "args": [
        "-y",
        "kubernetes-mcp-server@latest"
      ]
    }
  },
  "preferences": {
    "coworkScheduledTasksEnabled": true,
    "ccdScheduledTasksEnabled": true,
    "sidebarMode": "code",
    "coworkWebSearchEnabled": true
  }
}
```

Get the NLB hostname and substitute it into the config above:
```bash
kubectl get svc easy-cass-mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

> **Re-deploy note:** Every time you tear down and redeploy the workshop, a new NLB is provisioned with a different hostname. The project's `.mcp.json` (used by Claude Code) is rewritten automatically by `scripts/deploy.sh`, but `claude_desktop_config.json` (used by Claude Desktop) is **not** — you'll need to manually update the `easy-cass-mcp` URL there after each redeploy.

### 4. Run a Load Test (Optional)

```bash
kubectl apply -f manifests/loadtest/nosqlbench-job.yaml
```

This runs a 3-phase CQL workload: schema creation, 500k row rampup, then 1 hour of mixed 50/50 read/write at 100,000 ops/sec. To re-run, delete the old job first:

```bash
kubectl delete job nosqlbench-load && kubectl apply -f manifests/loadtest/nosqlbench-job.yaml
```

## Teardown

```bash
./scripts/teardown.sh
```

This removes all workshop resources in reverse order. To delete the EKS cluster itself:
```bash
eksctl delete cluster --name k8ssandra-cluster --region us-east-1
```

## Directory Structure

```
k8ssandra-workshop/
├── CLAUDE.md                              # AI assistant context
├── README.md
├── manifests/
│   ├── infra/
│   │   ├── eksctl-cluster.yaml            # EKS ClusterConfig (node groups, addons)
│   │   └── storageclass.yaml              # EBS gp3 StorageClass
│   ├── cassandra/
│   │   └── k8ssandra-cluster.yaml         # K8ssandraCluster CR (3 nodes)
│   ├── apps/
│   │   ├── easy-cass-mcp-deployment.yaml  # MCP server deployment
│   │   └── easy-cass-mcp-service.yaml     # Internet-facing NLB service
│   └── loadtest/
│       ├── nosqlbench-configmap.yaml       # CQL key-value workload
│       └── nosqlbench-job.yaml            # Load test Job
├── docs/
│   └── TROUBLESHOOTING.md
└── scripts/
    ├── deploy.sh                          # Full deployment orchestration
    └── teardown.sh                        # Resource cleanup
```

## Key Gotchas

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| NLB won't provision | Subnets missing load balancer tags | Ensure cluster was created with the provided ClusterConfig (eksctl tags subnets automatically) |
| Webhook errors on K8ssandraCluster | Operator in wrong namespace | Install k8ssandra-operator to `default` namespace |
| easy-cass-mcp unreachable via NLB | FastMCP binds to 127.0.0.1 by default | Set `FASTMCP_SERVER_HOST=0.0.0.0` (already configured) |
| Claude Desktop "No such file" | `npx`/`kubectl` not in Claude's PATH | Symlink to `/usr/local/bin` |
| NoSQLBench `nb5: not found` | Docker entrypoint override | Use `java -jar /nb5.jar` (already configured) |

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the full troubleshooting guide.

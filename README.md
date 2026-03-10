# K8ssandra on EKS Workshop

A complete workshop environment running Apache Cassandra on Amazon EKS using k8ssandra-operator, with MCP-based AI tooling for cluster management.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  EKS Cluster (Auto Mode) — k8ssandra-cluster                │
│  Region: us-east-1 | VPC: cassandra-mcp-vpc                 │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ Cassandra     │  │ Cassandra     │  │ Cassandra     │      │
│  │ Node 0 (dc1) │  │ Node 1 (dc1) │  │ Node 2 (dc1) │      │
│  │ 5Gi gp3 EBS  │  │ 5Gi gp3 EBS  │  │ 5Gi gp3 EBS  │      │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐                  │
│  │ k8ssandra-operator│  │ cass-operator    │                  │
│  └──────────────────┘  └──────────────────┘                  │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐                  │
│  │ easy-cass-mcp    │  │ cert-manager     │                  │
│  │ (NLB: port 8000) │  │                  │                  │
│  └──────────────────┘  └──────────────────┘                  │
│                                                              │
│  ┌──────────────────┐                                        │
│  │ NoSQLBench Job   │  (on-demand load testing)              │
│  └──────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
         │
         │ NLB (internet-facing, port 8000)
         ▼
┌─────────────────┐
│  Claude Desktop  │ ← mcp-remote bridge to easy-cass-mcp
│  + Kubernetes    │ ← Kubernetes MCP (API-based)
│    MCP Server    │
└─────────────────┘
```

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Apache Cassandra | 4.0.1 | Database (3-node cluster, dc1) |
| k8ssandra-operator | 1.26.0 | Cassandra lifecycle management |
| cert-manager | v1.18.2 | TLS certificate management for webhooks |
| easy-cass-mcp | latest | MCP server for AI-powered Cassandra management |
| NoSQLBench | latest | Load testing and benchmarking |

## Prerequisites

- AWS CLI configured with appropriate permissions
- `kubectl` installed and configured
- `eksctl` (for EKS Auto Mode cluster creation)
- Helm 3.x
- Node.js 18+ (for `mcp-remote` bridge)
- Claude Desktop (for MCP integration)

## Quick Start

### 1. Create the EKS Cluster

```bash
eksctl create cluster \
  --name k8ssandra-cluster \
  --region us-east-1 \
  --enable-auto-mode \
  --vpc-cidr 10.0.0.0/16
```

### 2. Tag Subnets

Tag private subnets for internal load balancers:
```bash
aws ec2 create-tags --resources <private-subnet-ids> \
  --tags Key=kubernetes.io/role/internal-elb,Value=1 --region us-east-1
```

Tag public subnets for internet-facing load balancers:
```bash
aws ec2 create-tags --resources <public-subnet-ids> \
  --tags Key=kubernetes.io/role/elb,Value=1 --region us-east-1
```

### 3. Deploy Everything

```bash
./scripts/deploy.sh
```

### 4. Configure Claude Desktop

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
    }
  }
}
```

Get the NLB hostname:
```bash
kubectl get svc easy-cass-mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## Directory Structure

```
k8ssandra-workshop/
├── README.md
├── manifests/
│   ├── infra/
│   │   └── storageclass.yaml          # EBS gp3 StorageClass for EKS Auto Mode
│   ├── cassandra/
│   │   └── k8ssandra-cluster.yaml     # K8ssandraCluster CR (3-node, dc1)
│   ├── apps/
│   │   ├── easy-cass-mcp-deployment.yaml
│   │   └── easy-cass-mcp-service.yaml
│   └── loadtest/
│       ├── nosqlbench-configmap.yaml   # CQL key-value workload definition
│       └── nosqlbench-job.yaml         # 30-min load test Job
├── docs/
│   └── TROUBLESHOOTING.md
└── scripts/
    ├── deploy.sh
    └── teardown.sh
```

## Key Learnings / Gotchas

- **EKS Auto Mode EBS CSI**: Uses `ebs.csi.eks.amazonaws.com`, NOT `ebs.csi.aws.com`
- **k8ssandra-operator namespace**: Must install to `default` namespace — the chart deploys workloads to the Helm release namespace, and webhook configs must match
- **Cassandra driver port-forward**: The Python driver discovers all node IPs and tries to connect directly — use `WhiteListRoundRobinPolicy` or run MCP server in-cluster
- **FastMCP host binding**: Set `FASTMCP_SERVER_HOST=0.0.0.0` to allow traffic from outside the container
- **Claude Desktop remote MCP**: Use `npx mcp-remote <url> --allow-http` for non-HTTPS endpoints
- **NoSQLBench Docker image**: Binary is at `/nb5.jar`, invoke with `java -jar /nb5.jar`

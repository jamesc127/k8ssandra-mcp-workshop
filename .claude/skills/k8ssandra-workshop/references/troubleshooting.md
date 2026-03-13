# K8ssandra Workshop — Troubleshooting Reference

## EKS / Infrastructure

### Pods Pending: ImagePullBackOff

Nodes in public subnets cannot reach ECR without a NAT Gateway.

**Diagnosis:**
```bash
kubectl describe pod <pod-name> -n default | grep -A 10 Events
```

**Fix:** The provided ClusterConfig (`manifests/infra/eksctl-cluster.yaml`) uses `privateNetworking: true` to place nodes in private subnets with NAT Gateway access. This should not occur if the cluster was created with the provided config. For custom VPCs, verify nodes are in private subnets with a NAT Gateway route.

---

### StorageClass PVC Failures: "provisioner is not supported"

**Diagnosis:**
```bash
kubectl get storageclass
kubectl describe pvc -n default
```

**Fix:** Re-apply the correct StorageClass (provisioner must be `ebs.csi.aws.com`):
```bash
kubectl apply -f manifests/infra/storageclass.yaml
kubectl get storageclass ebs-gp3
```

Verify EBS CSI addon is installed:
```bash
aws eks describe-addon \
  --cluster-name k8ssandra-cluster \
  --addon-name aws-ebs-csi-driver \
  --region us-east-1
```

---

### NLB Not Provisioning: "unable to resolve at least one subnet"

**Diagnosis:**
```bash
kubectl describe svc easy-cass-mcp -n default | grep -A 10 Events
```

Look for: `Failed build model due to ... unable to resolve at least one subnet`.

**Fix:** eksctl auto-tags subnets when using the provided ClusterConfig. For custom VPCs, find and tag subnets manually:

```bash
# Find your cluster's VPC ID
aws eks describe-cluster \
  --name k8ssandra-cluster \
  --region us-east-1 \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text

# Find public subnets in that VPC
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
            "Name=map-public-ip-on-launch,Values=true" \
  --query "Subnets[*].SubnetId" \
  --output text --region us-east-1

# Tag public subnets for internet-facing NLB
aws ec2 create-tags \
  --resources <SUBNET_ID_1> <SUBNET_ID_2> \
  --tags Key=kubernetes.io/role/elb,Value=1 \
  --region us-east-1

# Tag private subnets for internal NLB
aws ec2 create-tags \
  --resources <PRIVATE_SUBNET_ID_1> <PRIVATE_SUBNET_ID_2> \
  --tags Key=kubernetes.io/role/internal-elb,Value=1 \
  --region us-east-1
```

After tagging, delete and re-create the service to re-trigger NLB provisioning:
```bash
kubectl delete svc easy-cass-mcp -n default
kubectl apply -f manifests/apps/easy-cass-mcp-service.yaml
```

---

## k8ssandra-operator

### Webhook "service not found" When Creating K8ssandraCluster

**Diagnosis:**
```bash
kubectl apply -f manifests/cassandra/k8ssandra-cluster.yaml
# Error: failed calling webhook "..." service "k8ssandra-operator-webhook..." not found
```

**Fix:** The operator must be in the `default` namespace. Check where it's installed:
```bash
helm list -A | grep k8ssandra
```

If it shows a namespace other than `default`, reinstall:
```bash
helm uninstall k8ssandra-operator -n <wrong-namespace>
helm install k8ssandra-operator k8ssandra/k8ssandra-operator \
  --namespace default --wait --timeout 5m
```

---

### K8ssandraCluster Stuck in Initializing

**Diagnosis:**
```bash
kubectl get k8ssandracluster demo -n default
kubectl describe k8ssandracluster demo -n default
kubectl get pods -l app.kubernetes.io/name=cassandra -n default
kubectl describe pod <cassandra-pod> -n default
```

Check cert-manager is fully ready (required for operator webhooks):
```bash
kubectl get pods -n cert-manager
kubectl get certificates -n default
```

---

## easy-cass-mcp

### MCP Server Binds to 127.0.0.1 — NLB Cannot Reach It

FastMCP defaults to `127.0.0.1`. The NLB health checks and forwarded traffic hit the pod IP, so the server must listen on `0.0.0.0`.

**Diagnosis:**
```bash
kubectl exec deployment/easy-cass-mcp -n default -- env | grep FASTMCP
# Should show: FASTMCP_SERVER_HOST=0.0.0.0
```

**Fix:** Re-apply the deployment manifest (already has the correct env var):
```bash
kubectl apply -f manifests/apps/easy-cass-mcp-deployment.yaml
```

Note: `UVICORN_HOST` and `HOST` env vars do NOT override the FastMCP bind address — only `FASTMCP_SERVER_HOST` works.

---

### Claude Desktop Cannot Connect to MCP Server

Claude Desktop does not support `"type": "streamable-http"` natively. Use `mcp-remote` as a stdio bridge:

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

The `--allow-http` flag is required. Without it, mcp-remote refuses non-localhost HTTP URLs.

---

### Claude Desktop "Failed to spawn process: No such file or directory"

Claude Desktop has a restricted PATH that doesn't include Homebrew or nvm locations.

**Fix:** Symlink required binaries to `/usr/local/bin`:
```bash
sudo ln -sf $(which npx) /usr/local/bin/npx
sudo ln -sf $(which kubectl) /usr/local/bin/kubectl
sudo ln -sf $(which aws) /usr/local/bin/aws
```

Restart Claude Desktop after symlinking.

---

## NoSQLBench

### "Unable to load path 'cql-keyvalue'"

The NoSQLBench Docker image does not bundle the `cql-keyvalue` built-in workload.

**Fix:** Ensure the ConfigMap is applied before the Job:
```bash
kubectl apply -f manifests/loadtest/nosqlbench-configmap.yaml
kubectl apply -f manifests/loadtest/nosqlbench-job.yaml
```

---

### "nb5: not found"

When the container command is overridden with `/bin/bash`, `nb5` is not in PATH.

**Fix:** All Job specs must invoke `java -jar /nb5.jar` (already correct in `manifests/loadtest/nosqlbench-job.yaml`).

---

### Binding Parse Errors with `<<template>>` Syntax

NB5 `<<var:default>>` template variable syntax is not supported in this version.

**Fix:** Hardcode values directly in the workload YAML. The provided `nosqlbench-configmap.yaml` does this correctly.

---

### Job Already Exists When Re-Running

Kubernetes Jobs are immutable once created.

**Fix:**
```bash
kubectl delete job nosqlbench-load -n default
kubectl apply -f manifests/loadtest/nosqlbench-job.yaml
```

---

## Cassandra Driver

### "Connection refused" from Local Machine

The Cassandra Python driver discovers all pod IPs during handshake and tries direct connections to `10.0.x.x` addresses, which are not routable outside the cluster.

**Fix:** Keep easy-cass-mcp as an in-cluster deployment (as configured). The NLB routes to the pod, which connects to Cassandra via internal DNS (`demo-dc1-all-pods-service.default.svc.cluster.local`). Do not run easy-cass-mcp locally.

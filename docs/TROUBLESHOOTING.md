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

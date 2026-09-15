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

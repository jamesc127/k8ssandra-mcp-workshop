# Medusa S3 backend — bucket and IRSA setup

Run these **once per cluster**, before `scripts/deploy.sh`. They are deliberately
out-of-band: `deploy.sh` never creates IAM resources, it only checks that they exist
and fails fast if they don't.

Requires `withOIDC: true` in the eksctl ClusterConfig (already set in both profiles).

## 1. Create the bucket

```bash
export AWS_PROFILE=k8ssandra-workshop
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=k8ssandra-workshop-backups-$ACCOUNT
REGION=us-east-1

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Workshop data is disposable — expire it so a forgotten bucket doesn't accrue cost.
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration '{"Rules":[{"ID":"expire","Status":"Enabled","Filter":{},"Expiration":{"Days":7}}]}'
```

## 2. Create the IAM policy

```bash
cat > /tmp/medusa-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": "arn:aws:s3:::$BUCKET"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::$BUCKET/*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name MedusaS3Workshop \
  --policy-document file:///tmp/medusa-policy.json
```

## 3. Create the IRSA service account

```bash
eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" --region "$REGION" \
  --namespace default --name medusa-backup \
  --attach-policy-arn "arn:aws:iam::$ACCOUNT:policy/MedusaS3Workshop" \
  --approve --override-existing-serviceaccounts
```

## 4. Put the bucket name in the CR

`manifests/cassandra/k8ssandra-cluster.yaml` (and `-full.yaml`) ship with a
placeholder. Replace it:

```bash
sed -i '' "s/REPLACE_WITH_MEDUSA_BUCKET/$BUCKET/" \
  manifests/cassandra/k8ssandra-cluster.yaml \
  manifests/cassandra/k8ssandra-cluster-full.yaml
```

## 5. Verify

Before deploying:

```bash
kubectl get sa medusa-backup -n default \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
```
Must print a role ARN. `deploy.sh` checks this and refuses to continue otherwise.

After the Cassandra pods are up:

```bash
kubectl exec demo-dc1-rack1-sts-0 -c medusa -- env | grep AWS_
```
Must show `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`. If those are absent,
the pod did not get the IRSA projection — check that `spec.cassandra.serviceAccount`
is `medusa-backup` in the CR.

## Fallback: static credentials

If IRSA cannot be made to work in the provisioning account, use an access key
instead. **Remove `credentialsType: role-based` from the CR** — the reconciler
rejects having both a secret and role-based auth.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: medusa-bucket-key
  namespace: default
type: Opaque
stringData:
  credentials: |-
    [default]
    aws_access_key_id = <key>
    aws_secret_access_key = <secret>
```

and in the CR:

```yaml
  medusa:
    storageProperties:
      storageProvider: s3
      storageSecretRef:
        name: medusa-bucket-key
      # credentialsType removed
```

## Teardown

`scripts/teardown.sh` leaves the bucket and the IAM role alone, since they are
out-of-band assets. To remove them:

```bash
aws s3 rm "s3://$BUCKET" --recursive
aws s3api delete-bucket --bucket "$BUCKET"
eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --namespace default --name medusa-backup
aws iam delete-policy --policy-arn "arn:aws:iam::$ACCOUNT:policy/MedusaS3Workshop"
```

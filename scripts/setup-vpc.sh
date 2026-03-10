#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-vpc.sh — Discover and tag EKS VPC subnets for load balancer placement
#
# EKS Auto Mode requires specific subnet tags for NLB provisioning:
#   - Private subnets: kubernetes.io/role/internal-elb=1
#   - Public subnets:  kubernetes.io/role/elb=1
#
# This script attempts to auto-detect public vs private subnets by checking
# route table associations for an Internet Gateway (public) vs NAT Gateway
# (private). If auto-detection fails, it prints manual commands.
# =============================================================================

CLUSTER_NAME="${1:-k8ssandra-cluster}"
REGION="${2:-us-east-1}"
DRY_RUN="${DRY_RUN:-false}"

echo "============================================"
echo "  EKS VPC Subnet Tagging"
echo "============================================"
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "Region:  $REGION"
echo ""

# Step 1: Get VPC ID from EKS cluster
echo ">>> Discovering VPC from EKS cluster..."
VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text 2>/dev/null)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "ERROR: Could not find VPC for cluster '$CLUSTER_NAME' in region '$REGION'"
  echo "Make sure the cluster exists and your AWS credentials are configured."
  exit 1
fi
echo "    VPC: $VPC_ID"
echo ""

# Step 2: List all subnets in the VPC
echo ">>> Discovering subnets..."
ALL_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{SubnetId:SubnetId,CidrBlock:CidrBlock,AZ:AvailabilityZone,MapPublicIp:MapPublicIpOnLaunch}' \
  --region "$REGION" \
  --output json)

SUBNET_COUNT=$(echo "$ALL_SUBNETS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "    Found $SUBNET_COUNT subnets in VPC $VPC_ID"
echo ""

if [ "$SUBNET_COUNT" -eq 0 ]; then
  echo "ERROR: No subnets found. Check VPC ID and permissions."
  exit 1
fi

# Step 3: Classify subnets as public or private using route tables
# A subnet is PUBLIC if its route table has a route to an Internet Gateway (igw-*)
# A subnet is PRIVATE if its route table routes 0.0.0.0/0 to a NAT Gateway (nat-*)
echo ">>> Classifying subnets by route table analysis..."
echo ""

PUBLIC_SUBNETS=()
PRIVATE_SUBNETS=()

SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].SubnetId' \
  --region "$REGION" \
  --output text)

for SUBNET_ID in $SUBNET_IDS; do
  # Get the route table associated with this subnet
  # First check explicit associations, then fall back to main route table
  RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query 'RouteTables[0].RouteTableId' \
    --region "$REGION" \
    --output text 2>/dev/null)

  if [ -z "$RT_ID" ] || [ "$RT_ID" = "None" ]; then
    # No explicit association — use the main route table for the VPC
    RT_ID=$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' \
      --region "$REGION" \
      --output text 2>/dev/null)
  fi

  # Check if the route table has a route to an Internet Gateway
  IGW_ROUTE=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" \
    --region "$REGION" \
    --output text 2>/dev/null)

  # Get subnet details for display
  SUBNET_INFO=$(aws ec2 describe-subnets \
    --subnet-ids "$SUBNET_ID" \
    --query 'Subnets[0].{CIDR:CidrBlock,AZ:AvailabilityZone}' \
    --region "$REGION" \
    --output text 2>/dev/null)

  if [[ "$IGW_ROUTE" == igw-* ]]; then
    echo "    PUBLIC:  $SUBNET_ID  ($SUBNET_INFO)  route-table=$RT_ID  gateway=$IGW_ROUTE"
    PUBLIC_SUBNETS+=("$SUBNET_ID")
  else
    echo "    PRIVATE: $SUBNET_ID  ($SUBNET_INFO)  route-table=$RT_ID"
    PRIVATE_SUBNETS+=("$SUBNET_ID")
  fi
done

echo ""
echo "Summary: ${#PUBLIC_SUBNETS[@]} public, ${#PRIVATE_SUBNETS[@]} private"
echo ""

# Step 4: Apply tags
if [ "$DRY_RUN" = "true" ]; then
  echo ">>> DRY RUN — would apply the following tags:"
else
  echo ">>> Applying subnet tags..."
fi

if [ ${#PRIVATE_SUBNETS[@]} -gt 0 ]; then
  echo ""
  echo "    Tagging private subnets with kubernetes.io/role/internal-elb=1"
  for SID in "${PRIVATE_SUBNETS[@]}"; do
    echo "      $SID"
  done
  if [ "$DRY_RUN" != "true" ]; then
    aws ec2 create-tags \
      --resources "${PRIVATE_SUBNETS[@]}" \
      --tags Key=kubernetes.io/role/internal-elb,Value=1 \
      --region "$REGION"
    echo "    ✓ Done"
  fi
fi

if [ ${#PUBLIC_SUBNETS[@]} -gt 0 ]; then
  echo ""
  echo "    Tagging public subnets with kubernetes.io/role/elb=1"
  for SID in "${PUBLIC_SUBNETS[@]}"; do
    echo "      $SID"
  done
  if [ "$DRY_RUN" != "true" ]; then
    aws ec2 create-tags \
      --resources "${PUBLIC_SUBNETS[@]}" \
      --tags Key=kubernetes.io/role/elb,Value=1 \
      --region "$REGION"
    echo "    ✓ Done"
  fi
fi

echo ""
echo "============================================"
echo "  Tagging Complete!"
echo "============================================"

# Step 5: Print manual commands as reference
echo ""
echo "============================================"
echo "  Manual Commands (in case auto-detection"
echo "  didn't work correctly)"
echo "============================================"
echo ""
echo "# 1. List ALL subnets in your VPC:"
echo "aws ec2 describe-subnets \\"
echo "  --filters \"Name=vpc-id,Values=$VPC_ID\" \\"
echo "  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone]' \\"
echo "  --region $REGION --output table"
echo ""
echo "# 2. Check which subnets are currently tagged:"
echo "aws ec2 describe-subnets \\"
echo "  --filters \"Name=vpc-id,Values=$VPC_ID\" \\"
echo "  --query 'Subnets[].[SubnetId,CidrBlock,Tags[?Key==\`kubernetes.io/role/elb\`].Value|[0],Tags[?Key==\`kubernetes.io/role/internal-elb\`].Value|[0]]' \\"
echo "  --region $REGION --output table"
echo ""
echo "# 3. Check a subnet's route table to determine public vs private:"
echo "#    (If the default route points to igw-* it's public, nat-* it's private)"
echo "aws ec2 describe-route-tables \\"
echo "  --filters \"Name=association.subnet-id,Values=<SUBNET_ID>\" \\"
echo "  --query 'RouteTables[].Routes[?DestinationCidrBlock==\`0.0.0.0/0\`].[GatewayId,NatGatewayId]' \\"
echo "  --region $REGION --output table"
echo ""
echo "# 4. Manually tag PRIVATE subnets (for internal NLBs):"
echo "aws ec2 create-tags --resources <PRIVATE_SUBNET_IDS> \\"
echo "  --tags Key=kubernetes.io/role/internal-elb,Value=1 \\"
echo "  --region $REGION"
echo ""
echo "# 5. Manually tag PUBLIC subnets (for internet-facing NLBs):"
echo "aws ec2 create-tags --resources <PUBLIC_SUBNET_IDS> \\"
echo "  --tags Key=kubernetes.io/role/elb,Value=1 \\"
echo "  --region $REGION"
echo ""
echo "# 6. Update EKS to only place nodes in private subnets:"
echo "#    (Prevents Karpenter from placing nodes in public subnets without NAT)"
echo "aws eks update-cluster-config --name $CLUSTER_NAME \\"
echo "  --resources-vpc-config subnetIds=<PRIVATE_SUBNET_1>,<PRIVATE_SUBNET_2>,<PRIVATE_SUBNET_3> \\"
echo "  --region $REGION"
echo ""

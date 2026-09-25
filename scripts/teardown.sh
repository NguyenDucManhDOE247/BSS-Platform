#!/usr/bin/env bash
# Tear down an environment to stop the AWS billing meter.
# Usage:
#   ./scripts/teardown.sh dev
#   ./scripts/teardown.sh staging
#
# NEVER use this on prod without explicit confirmation in CI.
set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ] || [[ ! "$ENV" =~ ^(dev|staging|prod)$ ]]; then
  echo "Usage: $0 <dev|staging|prod>" >&2
  exit 1
fi

if [ "$ENV" = "prod" ]; then
  echo "⚠ You're about to destroy PROD. Type 'destroy-prod' to confirm:"
  read -r confirmation
  if [ "$confirmation" != "destroy-prod" ]; then
    echo "Aborted."
    exit 1
  fi
fi

REGION="${AWS_REGION:-ap-southeast-1}"
CLUSTER="bss-$ENV-eks"

# Giai đoạn 6 (ADR-006: staging/prod are destroyed after every session): the ALB is created by the
# AWS Load Balancer Controller from the Ingress — it is NOT in the Terraform state, so `terraform
# destroy` knows nothing about it. Left alone, the ALB (and its ENIs/security group) still live in the
# VPC and destroy hangs on DependencyViolation for ~20 minutes and then fails, while the ALB keeps
# billing. Deleting the Ingress FIRST, while the controller is still running, makes the controller
# remove the ALB itself; `--wait` blocks until its finalizer says it is gone.
if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  echo "→ Deleting Ingress (so the AWS LB Controller removes the ALB) on $CLUSTER..."
  if aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1 \
     && kubectl -n bss delete ingress --all --wait=true --timeout=5m; then
    echo "  ✓ Ingress gone"
  else
    echo "  ⚠ Could not delete the Ingress (endpoint unreachable / no permission / controller down)."
    echo "    Check after destroy for a leftover ALB:  aws elbv2 describe-load-balancers --region $REGION"
  fi
else
  echo "→ Cluster $CLUSTER not found — skipping Ingress cleanup."
fi

cd "$(dirname "$0")/../infrastructure/terraform/environments/$ENV"

echo "→ Terraform destroy on $ENV..."
terraform destroy -auto-approve

echo ""
echo "✓ $ENV torn down."
echo "  Note: S3 tfstate bucket + DynamoDB lock table are PRESERVED — they're"
echo "  account-level (created by bootstrap-aws.sh)."
echo ""
echo "  Leftover check (each should print nothing / an empty list):"
echo "    aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[].LoadBalancerName'"
echo "    aws ec2 describe-nat-gateways --region $REGION --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'"
echo "    aws ec2 describe-volumes --region $REGION --filters Name=status,Values=available --query 'Volumes[].VolumeId'"

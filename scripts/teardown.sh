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
ROOT="$(cd "$(dirname "$0")/.." && pwd)" # tuyệt đối — script `cd` sang thư mục Terraform ở dưới

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
    # Dọn nợ GĐ4 (lỗi thật, orphan_finder bắt được 2026-09-29): Ingress biến mất khi ALB đã xóa, nhưng
    # Target Group controller xóa SAU đó — destroy giết controller trước → 3 Target Group k8s-bss-* mồ côi
    # (VPC đã mất). Chờ tối đa 2 phút cho controller tự dọn; còn thì xóa theo tag cluster (chỉ TG của mình).
    for _ in $(seq 1 24); do
      tgs="$(aws elbv2 describe-target-groups --region "$REGION" --query "TargetGroups[?starts_with(TargetGroupName,'k8s-bss')].TargetGroupArn" --output text 2>/dev/null || true)"
      mine=""
      for arn in $tgs; do
        c="$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$arn" --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value" --output text 2>/dev/null || true)"
        [ "$c" = "$CLUSTER" ] && mine="$mine $arn"
      done
      [ -z "$mine" ] && break
      sleep 5
    done
    for arn in $mine; do
      aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn" && echo "  ✓ xóa Target Group sót: ${arn##*/targetgroup/}"
    done
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
# Lưới an toàn cuối (dọn nợ GĐ4): tools/ops/orphan_finder.py liệt kê mọi thứ BSS còn tính tiền (kể cả
# thứ không nằm trong state: ALB/Target Group từ Ingress, EC2 từ Karpenter). Chỉ đọc; exit 1 nếu còn sót.
if command -v python >/dev/null 2>&1 && python -c "import boto3" >/dev/null 2>&1; then
  echo ""
  PYTHONIOENCODING=utf-8 python "$ROOT/tools/ops/orphan_finder.py" --region "$REGION"     || echo "  ⚠ Còn tài nguyên sót — xử lý trước khi kết thúc buổi (xem danh sách trên)."
fi

echo "  Leftover check (each should print nothing / an empty list):"
echo "    aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[].LoadBalancerName'"
echo "    aws ec2 describe-nat-gateways --region $REGION --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'"
echo "    aws ec2 describe-volumes --region $REGION --filters Name=status,Values=available --query 'Volumes[].VolumeId'"

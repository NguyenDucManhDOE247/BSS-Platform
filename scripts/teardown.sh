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
  # Dọn nợ GĐ7 (lỗi thật 2026-09-29, orphan_finder bắt được): PVC của Prometheus/Grafana/Alertmanager là
  # EBS volume do EBS CSI tạo — KHÔNG nằm trong state. Destroy cluster trước khi xóa PVC → 3 volume mồ côi
  # (2+5+10 GiB). Xóa PVC khi CSI driver còn chạy → CSI tự xóa volume (reclaimPolicy Delete).
  echo "→ Deleting all PVCs (so the EBS CSI driver deletes their EBS volumes)..."
  if kubectl delete pvc --all --all-namespaces --wait=true --timeout=5m >/dev/null 2>&1; then
    echo "  ✓ PVCs gone"
  else
    echo "  ⚠ Some PVCs/volumes may remain — orphan_finder at the end will list them"
  fi

  # ADR-010: node do Karpenter tạo cũng KHÔNG nằm trong state Terraform (cùng lý do với ALB). Xóa
  # NodePool khi controller còn chạy → Karpenter tự drain + terminate node của nó; chờ NodeClaim hết.
  # Bỏ qua lặng lẽ ở môi trường không cài Karpenter (không có CRD NodePool).
  if kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then
    # Lỗi thật 2026-09-29: bước này hết 5 phút mà node Karpenter vẫn còn → destroy xóa cluster, 2 EC2 mồ côi
    # giữ security group của cluster → subnet + VPC treo tới khi xóa tay. Nghi vấn chính (log không đủ để
    # khẳng định): drain bị chặn bởi PDB minAvailable 1 của service 1 replica — đúng bài học drain GĐ8.
    # Đang phá cả môi trường nên bỏ PDB trước; NodePool còn có terminationGracePeriod (drain không treo mãi).
    kubectl -n bss delete pdb --all >/dev/null 2>&1 || true
    echo "→ Deleting Karpenter NodePools (so Karpenter terminates the EC2 nodes it launched)..."
    if kubectl delete nodepool --all --wait=true --timeout=5m \
       && kubectl wait --for=delete nodeclaim --all --timeout=5m 2>/dev/null; then
      echo "  ✓ Karpenter nodes gone"
    else
      # Dự phòng: terminate THẲNG theo tag (chỉ EC2 của cluster này + do Karpenter tạo), TRƯỚC destroy —
      # không thì chúng giữ security group của cluster và VPC không xóa được.
      ids="$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" Name=tag-key,Values=karpenter.sh/nodepool \
                  Name=instance-state-name,Values=pending,running,stopping,stopped \
        --query 'Reservations[].Instances[].InstanceId' --output text)"
      if [ -n "$ids" ]; then
        echo "  ⚠ Karpenter nodes still there after 5m — terminating by tag: $ids"
        # shellcheck disable=SC2086 # tách danh sách id thành nhiều tham số
        aws ec2 terminate-instances --region "$REGION" --instance-ids $ids >/dev/null \
          && aws ec2 wait instance-terminated --region "$REGION" --instance-ids $ids \
          && echo "  ✓ terminated"
      fi
    fi
  fi
else
  echo "→ Cluster $CLUSTER not found — skipping Ingress cleanup."
fi

# Lỗi thật 2026-09-30 (rà Definition of Done): destroy dừng ở "DeleteSubnet … DependencyViolation".
# Thủ phạm: 1 ENI phụ mà VPC CNI gắn cho node Spot do Karpenter tạo — node bị terminate (bước NodePool ở
# trên) nhưng CNI KHÔNG thu hồi ENI (tag eks:eni:owner=amazon-vpc-cni, trạng thái `available`). ENI đó
# còn giữ security group của cluster → EKS không xóa được SG `eks-cluster-sg-<cluster>-*` → VPC cũng kẹt.
# Cả hai đều không nằm trong state Terraform. Dọn theo tag của ĐÚNG cluster này, rồi destroy lại 1 lần.
cleanup_vpc_leftovers() {
  local enis sgs id
  enis="$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=tag:cluster.k8s.amazonaws.com/name,Values=$CLUSTER" Name=status,Values=available \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
  for id in $enis; do
    aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$id" \
      && echo "  ✓ xóa ENI sót của VPC CNI: $id"
  done
  # SG do EKS tự tạo cho cluster — chỉ xóa khi cluster đã không còn.
  if ! aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
    sgs="$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=tag:aws:eks:cluster-name,Values=$CLUSTER" --query 'SecurityGroups[].GroupId' --output text)"
    for id in $sgs; do
      aws ec2 delete-security-group --region "$REGION" --group-id "$id" \
        && echo "  ✓ xóa security group sót của EKS: $id"
    done
  fi
}

cd "$(dirname "$0")/../infrastructure/terraform/environments/$ENV"

echo "→ Removing VPC-CNI ENIs left behind by terminated nodes (if any)..."
cleanup_vpc_leftovers
echo "→ Terraform destroy on $ENV..."
if ! terraform destroy -auto-approve; then
  echo "⚠ destroy failed — cleaning ENIs / EKS security groups that block the VPC, then retrying once..."
  cleanup_vpc_leftovers
  terraform destroy -auto-approve
fi

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
echo "    aws ec2 describe-instances --region $REGION --filters Name=tag-key,Values=karpenter.sh/nodepool Name=instance-state-name,Values=running,pending --query 'Reservations[].Instances[].InstanceId'"

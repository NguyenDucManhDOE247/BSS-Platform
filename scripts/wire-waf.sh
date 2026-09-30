#!/usr/bin/env bash
# Gắn Web ACL (tạo bởi module Terraform "waf") vào ALB thật của $ENV.
#
# Vì sao cần script riêng thay vì làm trong Terraform: ALB không phải resource Terraform trong repo
# này — AWS Load Balancer Controller tự tạo/xóa nó từ object Ingress (xem
# infrastructure/kubernetes/base/ingress.yaml và comment đầu
# infrastructure/terraform/modules/waf/main.tf). Controller đó hỗ trợ sẵn annotation
# `alb.ingress.kubernetes.io/wafv2-acl-arn` để tự gắn Web ACL — script này chỉ:
#   1. đọc ARN thật từ `terraform output` (ARN đổi mỗi lần Web ACL bị tạo lại, nên KHÔNG hardcode
#      vào overlay Kustomize như cách account id ở kustomization.yaml — xem ADR-004 cho bài học
#      tương tự với RDS hostname)
#   2. `kubectl annotate` lên Ingress đang chạy
#   3. chờ ALB có hostname rồi XÁC NHẬN THẬT association qua `aws wafv2 get-web-acl-for-resource`
#      (không chỉ tin annotation đã set là xong — Controller có thể log lỗi mà annotation vẫn còn đó)
#
# Chạy SAU `kubectl apply -k infrastructure/kubernetes/overlays/$ENV` (Ingress phải tồn tại trước).
# Idempotent — chạy lại an toàn (annotate --overwrite, so sánh ARN trước khi coi là xong).
#
# Usage: ./scripts/wire-waf.sh [dev|staging|prod]
set -euo pipefail

ENV="${1:-dev}"
REGION="${AWS_REGION:-ap-southeast-1}"
TF_DIR="infrastructure/terraform/environments/$ENV"
TIMEOUT="${WIRE_WAF_TIMEOUT_SECONDS:-180}"
INTERVAL="${WIRE_WAF_INTERVAL_SECONDS:-10}"

ACL_ARN="$(terraform -chdir="$TF_DIR" output -raw waf_web_acl_arn)"
echo "→ Web ACL ($ENV): $ACL_ARN"

echo "→ Annotate Ingress bss-ingress"
kubectl -n bss annotate ingress bss-ingress \
  alb.ingress.kubernetes.io/wafv2-acl-arn="$ACL_ARN" --overwrite

echo "→ Chờ Ingress có hostname (ALB)"
deadline=$((SECONDS + TIMEOUT))
HOST=""
while :; do
  HOST="$(kubectl -n bss get ingress bss-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -z "$HOST" ] || break
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "✗ Hết ${TIMEOUT}s mà Ingress vẫn chưa có hostname — xem: kubectl -n bss describe ingress bss-ingress"
    exit 1
  fi
  sleep "$INTERVAL"
done
echo "  ALB DNS: $HOST"

echo "→ Tra ALB ARN từ DNS name"
deadline=$((SECONDS + TIMEOUT))
ALB_ARN=""
while :; do
  ALB_ARN="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?DNSName=='$HOST'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)"
  if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "✗ Không tìm thấy ALB có DNSName=$HOST qua elbv2 describe-load-balancers"
    exit 1
  fi
  sleep "$INTERVAL"
done
echo "  ALB ARN: $ALB_ARN"

echo "→ Xác nhận association thật với AWS WAF"
deadline=$((SECONDS + TIMEOUT))
while :; do
  GOT_ARN="$(aws wafv2 get-web-acl-for-resource --region "$REGION" --resource-arn "$ALB_ARN" \
    --query 'WebACL.ARN' --output text 2>/dev/null || true)"
  if [ "$GOT_ARN" = "$ACL_ARN" ]; then
    echo "✓ ALB đã gắn đúng Web ACL ($ACL_ARN)."
    exit 0
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "✗ Hết ${TIMEOUT}s mà ALB chưa gắn đúng Web ACL (hiện tại: ${GOT_ARN:-none})."
    echo "  Kiểm tra: kubectl -n kube-system logs deploy/aws-load-balancer-controller"
    exit 1
  fi
  sleep "$INTERVAL"
done

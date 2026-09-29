#!/usr/bin/env bash
# Giai đoạn 7 (việc 2 — B-17, B-42): cài Fluent Bit (log Pod → CloudWatch Logs trên AWS, hoặc → 1
# sink HTTP cục bộ trên kind để tự kiểm tra parser mà không cần AWS).
#
# Usage:
#   ./scripts/logging-install.sh kind
#   ./scripts/logging-install.sh dev|staging|prod
set -euo pipefail

ENV="${1:-}"
[ -n "$ENV" ] || { echo "Usage: $0 kind|dev|staging|prod" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=amazon-cloudwatch
REGION="${AWS_REGION:-ap-southeast-1}"
CHART_VERSION="0.2.0" # ghim — xem comment ở đầu platform/logging/fluent-bit-values.yaml

log()  { echo "→ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

for c in kubectl helm; do command -v "$c" >/dev/null 2>&1 || fail "không tìm thấy '$c' trên PATH"; done

EXTRA_ARGS=()
if [ "$ENV" = "kind" ]; then
  CTX="kind-bss"
  VALUES="$ROOT_DIR/platform/logging/fluent-bit-values-local.yaml"
else
  command -v aws >/dev/null 2>&1 || fail "không tìm thấy 'aws' trên PATH"
  aws eks update-kubeconfig --region "$REGION" --name "bss-$ENV-eks" >/dev/null
  CTX="$(kubectl config current-context)"
  VALUES="$ROOT_DIR/platform/logging/fluent-bit-values.yaml"
  TF_DIR="$ROOT_DIR/infrastructure/terraform/environments/$ENV"
  ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw fluent_bit_role_arn 2>/dev/null || true)"
  [ -n "$ROLE_ARN" ] || fail "không lấy được output 'fluent_bit_role_arn' từ $TF_DIR — module platform-iam đã tạo role này chưa? (B-35)"
  CLUSTER="bss-$ENV-eks"
  EXTRA_ARGS+=(--set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ROLE_ARN"
               --set "cloudWatchLogs.logGroupName=/aws/eks/$CLUSTER/application")
fi
log "context: $CTX · values: ${VALUES#"$ROOT_DIR"/}"

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null

kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null

# Lỗi thật lần chạy EKS đầu (2026-09-29, Git Bash trên Windows): MSYS "dịch" mọi tham số trông như đường
# dẫn POSIX trước khi gọi helm.exe → "logGroupName=/aws/eks/..." thành "C:/Git/aws/eks/..." → Fluent Bit bị
# AccessDenied (IAM chỉ cho /aws/eks/<cluster>/*). Chỉ loại trừ ĐÚNG tham số đó — `-f /c/.../values.yaml`
# vẫn CẦN được dịch để helm.exe đọc được file. Biến này vô hại trên Linux/CI.
MSYS2_ARG_CONV_EXCL="cloudWatchLogs." helm --kube-context "$CTX" upgrade --install fluent-bit eks/aws-for-fluent-bit \
  --version "$CHART_VERSION" -n "$NS" -f "$VALUES" "${EXTRA_ARGS[@]}" --wait --timeout 5m

ok "Fluent Bit đã cài trên $CTX (namespace $NS, DaemonSet)"
kubectl --context "$CTX" -n "$NS" get pods -o wide

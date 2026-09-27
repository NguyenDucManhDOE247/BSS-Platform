#!/usr/bin/env bash
# Giai đoạn 7 (việc 3, tùy chọn — OTel Java agent → X-Ray): cài OpenTelemetry Collector.
# Không cài Java agent ở đây — agent được inject qua initContainer trong chính mỗi Deployment
# (infrastructure/kubernetes/base/*/deployment.yaml), không phải một addon cluster-wide.
#
# Usage:
#   ./scripts/tracing-install.sh kind                  # exporter "debug" — không cần AWS
#   ./scripts/tracing-install.sh dev|staging|prod       # exporter "awsxray" — cần IAM (Terraform output)
set -euo pipefail

ENV="${1:-}"
[ -n "$ENV" ] || { echo "Usage: $0 kind|dev|staging|prod" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=observability
REGION="${AWS_REGION:-ap-southeast-1}"
CHART_VERSION="0.108.0" # ghim — đổi cùng lúc với platform/README.md

log()  { echo "→ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

for c in kubectl helm; do command -v "$c" >/dev/null 2>&1 || fail "không tìm thấy '$c' trên PATH"; done

EXTRA_ARGS=()
if [ "$ENV" = "kind" ]; then
  CTX="kind-bss"
  VALUES="$ROOT_DIR/platform/tracing/otel-collector-values-local.yaml"
else
  command -v aws >/dev/null 2>&1 || fail "không tìm thấy 'aws' trên PATH"
  aws eks update-kubeconfig --region "$REGION" --name "bss-$ENV-eks" >/dev/null
  CTX="$(kubectl config current-context)"
  VALUES="$ROOT_DIR/platform/tracing/otel-collector-values.yaml"
  TF_DIR="$ROOT_DIR/infrastructure/terraform/environments/$ENV"
  ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw otel_collector_role_arn 2>/dev/null || true)"
  [ -n "$ROLE_ARN" ] || fail "không lấy được output 'otel_collector_role_arn' từ $TF_DIR — module platform-iam đã tạo role này chưa? (B-35)"
  EXTRA_ARGS+=(--set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ROLE_ARN")
fi
log "context: $CTX · values: ${VALUES#"$ROOT_DIR"/}"

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null

kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null

helm --kube-context "$CTX" upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --version "$CHART_VERSION" -n "$NS" -f "$VALUES" "${EXTRA_ARGS[@]}" --wait --timeout 5m

ok "OTel Collector đã cài trên $CTX (namespace $NS)"
if [ "$ENV" = "kind" ]; then
  cat <<EOF

Xem span nhận được (exporter debug — verbosity: detailed):
  kubectl --context $CTX -n $NS logs deploy/otel-collector -f | grep -A5 "Span #"
EOF
fi

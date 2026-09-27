#!/usr/bin/env bash
# Giai đoạn 7: cài Prometheus + Grafana + Alertmanager (kube-prometheus-stack) và nạp ServiceMonitor,
# alert rule, dashboard của BSS — MỘT lệnh, chạy được cho cả kind lẫn EKS.
#
# Trước đây chuỗi này là ~15 lệnh copy-paste trong platform/README.md (mục 8) và một bản khác cho kind:
# hai bản lệch nhau (AWS còn `adminPassword: CHANGE_ME` trong git, receiver Alertmanager rỗng). Gom về một
# script để hai môi trường đi cùng một đường — chỉ khác file values.
#
# Hai thứ bí mật KHÔNG nằm trong git/values/lịch sử Helm mà đi qua Kubernetes Secret:
#   1. Mật khẩu admin Grafana  -> Secret `grafana-admin` (tự sinh ngẫu nhiên lần đầu, giữ nguyên các lần sau)
#   2. URL webhook nhận cảnh báo -> Secret `alertmanager-webhook` (từ biến môi trường ALERT_WEBHOOK_URL)
# Alertmanager đọc URL từ FILE trong Secret (`webhook_url_file`/`api_url_file`/`url_file`) nên URL không lộ
# ra `helm get values`.
#
# Usage:
#   ./scripts/monitoring-install.sh kind                      # cluster kind `bss` (local, $0)
#   ./scripts/monitoring-install.sh dev|staging|prod          # EKS (cần aws cli + đã terraform apply)
# Biến môi trường tùy chọn:
#   ALERT_WEBHOOK_URL   URL webhook. Không đặt -> alert vẫn Firing nhưng KHÔNG ai nhận (script cảnh báo to).
#   ALERT_WEBHOOK_KIND  discord (mặc định) | slack | generic (Alertmanager POST JSON tới URL bất kỳ)
#   ALERT_SLACK_CHANNEL kênh Slack (mặc định #bss-alerts; chỉ dùng khi KIND=slack)
set -euo pipefail

ENV="${1:-}"
[ -n "$ENV" ] || { echo "Usage: $0 kind|dev|staging|prod" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON_DIR="$ROOT_DIR/platform/monitoring"
CHART_VERSION="91.4.0"   # kube-prometheus-stack — ghim; đổi cùng lúc với platform/README.md
NS=monitoring
REGION="${AWS_REGION:-ap-southeast-1}"

log()  { echo "→ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

for c in kubectl helm; do command -v "$c" >/dev/null 2>&1 || fail "không tìm thấy '$c' trên PATH"; done

if [ "$ENV" = "kind" ]; then
  CTX="kind-bss"
  VALUES="$MON_DIR/prometheus/values-local.yaml"
else
  command -v aws >/dev/null 2>&1 || fail "không tìm thấy 'aws' trên PATH"
  aws eks update-kubeconfig --region "$REGION" --name "bss-$ENV-eks" >/dev/null
  CTX="$(kubectl config current-context)"
  VALUES="$MON_DIR/prometheus/values.yaml"
fi
log "context: $CTX · values: ${VALUES#"$ROOT_DIR"/}"
K=(kubectl --context "$CTX")

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

"${K[@]}" create namespace "$NS" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null

# ── 1. Mật khẩu Grafana ────────────────────────────────────────────────────────────────────────────
if "${K[@]}" -n "$NS" get secret grafana-admin >/dev/null 2>&1; then
  log "Secret grafana-admin đã có — giữ nguyên"
else
  command -v openssl >/dev/null 2>&1 || fail "cần openssl để sinh mật khẩu Grafana"
  log "Tạo Secret grafana-admin với mật khẩu ngẫu nhiên"
  "${K[@]}" -n "$NS" create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 18 | tr -d '/+=')" >/dev/null
fi

# ── 2. Kênh cảnh báo (webhook) ─────────────────────────────────────────────────────────────────────
EXTRA_VALUES="$(mktemp)"
trap 'rm -f "$EXTRA_VALUES"' EXIT
KIND_HOOK="${ALERT_WEBHOOK_KIND:-discord}"
if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
  log "Tạo Secret alertmanager-webhook (kênh: $KIND_HOOK)"
  # printf %s: không thêm \n cuối — Alertmanager đọc nguyên nội dung file làm URL.
  "${K[@]}" -n "$NS" create secret generic alertmanager-webhook \
    --from-literal=url="$ALERT_WEBHOOK_URL" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
  FILE=/etc/alertmanager/secrets/alertmanager-webhook/url
  case "$KIND_HOOK" in
    discord) RECEIVER="        discord_configs:
          - webhook_url_file: $FILE
            send_resolved: true" ;;
    slack)   RECEIVER="        slack_configs:
          - api_url_file: $FILE
            channel: \"${ALERT_SLACK_CHANNEL:-#bss-alerts}\"
            send_resolved: true" ;;
    generic) RECEIVER="        webhook_configs:
          - url_file: $FILE
            send_resolved: true" ;;
    *) fail "ALERT_WEBHOOK_KIND phải là discord|slack|generic (nhận: $KIND_HOOK)" ;;
  esac
  # Helm KHÔNG gộp list: `receivers` của file này thay hẳn list trong values chính -> phải lặp lại
  # receiver "null" (Watchdog của chart trỏ vào nó — thiếu là Alertmanager không bao giờ được tạo).
  cat > "$EXTRA_VALUES" <<YAML
alertmanager:
  alertmanagerSpec:
    secrets: [alertmanager-webhook]
  config:
    receivers:
      - name: "null"
      - name: "default"
$RECEIVER
YAML
else
  warn "ALERT_WEBHOOK_URL chưa đặt: alert sẽ chuyển Firing NHƯNG KHÔNG AI NHẬN được thông báo."
  warn "Xem docs/runbooks/alerting-setup.md để tạo webhook Discord/Slack."
  echo "{}" > "$EXTRA_VALUES"
fi

# ── 3. Dashboard BSS — PHẢI có TRƯỚC khi cài chart ────────────────────────────────────────────────
# values.yaml gắn ConfigMap này vào Pod Grafana (`dashboardsConfigMaps`). Pod không khởi động được khi
# volume trỏ tới ConfigMap chưa tồn tại (`MountVolume.SetUp failed … configmap "bss-dashboards" not found`)
# → `helm --wait` chờ mãi. Lỗi thật lộ ra khi chạy script lần đầu trên kind (bản README cũ áp ConfigMap
# SAU helm và không dùng --wait nên không ai thấy).
log "Dashboard BSS (ConfigMap nhãn grafana_dashboard=1)"
"${K[@]}" -n "$NS" create configmap bss-dashboards \
  --from-file="$MON_DIR/grafana/dashboards/" --dry-run=client -o yaml \
  | "${K[@]}" label --local -f - grafana_dashboard=1 -o yaml \
  | "${K[@]}" apply -f - >/dev/null

# ── 4. Cài chart ───────────────────────────────────────────────────────────────────────────────────
log "helm upgrade --install monitoring (kube-prometheus-stack $CHART_VERSION) — vài phút lần đầu"
helm --kube-context "$CTX" upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "$CHART_VERSION" -n "$NS" -f "$VALUES" -f "$EXTRA_VALUES" --wait --timeout 10m

# ── 5. Object của BSS (cần CRD do chart vừa cài — B-40) ───────────────────────────────────────────
log "ServiceMonitor + PrometheusRule"
"${K[@]}" apply -f "$MON_DIR/service-monitor.yaml"
"${K[@]}" apply -f "$MON_DIR/alerts/"

ok "Monitoring đã cài trên $CTX"
cat <<EOT

Mật khẩu Grafana (user: admin):
  kubectl --context $CTX -n $NS get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
Xem qua port-forward:
  kubectl --context $CTX -n $NS port-forward svc/monitoring-grafana 3000:80
  kubectl --context $CTX -n $NS port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
  kubectl --context $CTX -n $NS port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093
EOT

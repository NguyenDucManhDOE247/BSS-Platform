#!/usr/bin/env bash
# Giai đoạn 7: chạy test đơn vị cho các PrometheusRule trong platform/monitoring/alerts/ bằng
# `promtool` (công cụ đi kèm Prometheus) — KHÔNG cần cluster, KHÔNG cần AWS, ~5 giây.
#
# Vì sao phải trích `.spec`? File YAML trong repo là CRD `PrometheusRule` (dùng cho Prometheus
# Operator: có apiVersion/kind/metadata bao ngoài). promtool chỉ hiểu định dạng "rule file" thuần
# (`groups: [...]`) — chính là nội dung của `.spec`. `yq '.spec'` bóc lớp vỏ CRD ra.
#
# promtool lấy từ: (1) PATH nếu có; (2) không thì chạy trong Docker (image chính thức prom/prometheus).
#
# Usage: ./scripts/test-alert-rules.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALERT_DIR="$ROOT_DIR/platform/monitoring/alerts"
PROM_IMAGE="prom/prometheus:v3.5.0"

log()  { echo "→ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

command -v yq >/dev/null 2>&1 || fail "cần yq (https://github.com/mikefarah/yq) — có sẵn trên ubuntu-latest của GitHub và trong ~/setup-wsl-dev-tools.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Mỗi bss-<tên>.yaml -> bss-<tên>.rules.yaml (bóc .spec). Tên .rules.yaml khớp `rule_files:` trong test.
shopt -s nullglob
rule_sources=("$ALERT_DIR"/bss-*.yaml)
[ "${#rule_sources[@]}" -gt 0 ] || fail "không thấy $ALERT_DIR/bss-*.yaml"
for src in "${rule_sources[@]}"; do
  name="$(basename "$src" .yaml)"
  yq '.spec' "$src" > "$WORK/$name.rules.yaml"
done
tests=("$ALERT_DIR"/tests/*.test.yaml)
[ "${#tests[@]}" -gt 0 ] || fail "không thấy test nào trong $ALERT_DIR/tests/"
cp "${tests[@]}" "$WORK/"

run_promtool() {
  if command -v promtool >/dev/null 2>&1; then
    (cd "$WORK" && promtool "$@")
  else
    command -v docker >/dev/null 2>&1 || fail "không có promtool lẫn docker"
    # MSYS_NO_PATHCONV: Git Bash trên Windows sẽ "sửa" đường dẫn /w thành C:/... nếu không tắt.
    MSYS_NO_PATHCONV=1 docker run --rm --user "$(id -u):$(id -g)" --entrypoint promtool -v "$WORK:/w" -w /w "$PROM_IMAGE" "$@"
  fi
}

for rules in "$WORK"/*.rules.yaml; do
  log "promtool check rules $(basename "$rules")"
  run_promtool check rules "$(basename "$rules")"
done

for t in "$WORK"/*.test.yaml; do
  log "promtool test rules $(basename "$t")"
  run_promtool test rules "$(basename "$t")"
done

ok "alert rules: mọi test đạt"

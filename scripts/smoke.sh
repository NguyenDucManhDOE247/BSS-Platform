#!/usr/bin/env bash
# Smoke test một môi trường qua ALB — và PHẢI thất bại (exit 1) khi có gì hỏng, vì CD dùng exit
# code này để quyết định rollback tự động (B-52; ADR-005).
#
# Usage:
#   ./scripts/smoke.sh dev                                    # tra ALB của bss-dev-eks qua kubectl
#   SMOKE_BASE_URL=http://localhost:8080 ./scripts/smoke.sh   # trỏ thẳng vào một gateway (local/kind/test)
#
# Biến môi trường:
#   SMOKE_TIMEOUT_SECONDS   tổng thời gian chờ MỖI phase (đợi ALB có hostname; mỗi endpoint đạt) — mặc định 300
#   SMOKE_INTERVAL_SECONDS  nghỉ giữa các lần thử — mặc định 10
#
# Vì sao có retry (Giai đoạn 6): ngay sau `rollout status` xong, ALB vẫn cần ~30–60 giây để đăng ký
# Pod mới vào target group (và vài phút cho ALB mới tạo). Smoke chạy đúng lúc đó mà không retry sẽ
# 502/503 "giả" và kích hoạt rollback oan. Retry chỉ che độ trễ hạ tầng — nếu endpoint thật sự hỏng,
# hết thời gian chờ vẫn exit 1.
#
# Lịch sử (B-52): bản đầu có 2 lỗi khiến script KHÔNG BAO GIỜ fail — (1) `curl | jq || echo` nuốt
# exit code; (2) gọi `/api/actuator/health` mà gateway không hề có route. Bản Giai đoạn 5 sửa cả
# hai; bản này thêm: retry, và kiểm NỘI DUNG (200 + `[]` cũng là hỏng — seed data không có).
set -euo pipefail

ENV="${1:-dev}"
REGION="${AWS_REGION:-ap-southeast-1}"
TIMEOUT="${SMOKE_TIMEOUT_SECONDS:-300}"
INTERVAL="${SMOKE_INTERVAL_SECONDS:-10}"

if [ -n "${SMOKE_BASE_URL:-}" ]; then
  BASE="${SMOKE_BASE_URL%/}"
else
  aws eks update-kubeconfig --region "$REGION" --name "bss-$ENV-eks" >/dev/null
  HOST=""
  deadline=$((SECONDS + TIMEOUT))
  while :; do
    HOST="$(kubectl -n bss get ingress bss-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [ -z "$HOST" ] || break
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "✗ Hết ${TIMEOUT}s mà Ingress vẫn chưa có hostname — ALB chưa được tạo (xem: kubectl -n bss describe ingress bss-ingress)."
      exit 1
    fi
    echo "… chờ ALB có hostname"
    sleep "$INTERVAL"
  done
  BASE="http://$HOST"
fi

echo "→ Smoke testing $BASE"

fail=0

# check LABEL PATH JQ_FILTER MÔ_TẢ — đạt khi HTTP 2xx VÀ `jq -e FILTER` đúng; thử lại tới hết TIMEOUT.
check() {
  local label="$1" path="$2" filter="$3" desc="$4" deadline attempt=0 body reason=""
  echo ""
  echo "→ $label"
  deadline=$((SECONDS + TIMEOUT))
  while :; do
    attempt=$((attempt + 1))
    if body="$(curl -fsS --max-time 10 "$BASE$path" 2>&1)"; then
      if jq -e "$filter" >/dev/null 2>&1 <<<"$body"; then
        echo "  ✓ ok (lần thử $attempt): $desc"
        return 0
      fi
      reason="HTTP 2xx nhưng nội dung không đạt ($desc): ${body:0:200}"
    else
      reason="${body:0:200}"
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep "$INTERVAL"
  done
  echo "  ✗ FAILED sau $attempt lần thử — $reason"
  return 1
}

# Endpoint NGHIỆP VỤ thật qua gateway (không phải /api/actuator/health — gateway không có route đó).
# productOffering được seed lúc khởi động (Flyway) nên healthy stack luôn trả ≥ 1 phần tử.
check "productOffering (product-catalog qua api-gateway)" \
  "/api/tmf-api/productCatalog/v4/productOffering" 'type == "array" and length > 0' "mảng có ≥ 1 gói cước" || fail=1
check "customer (customer-service qua api-gateway)" \
  "/api/tmf-api/customerManagement/v4/customer" 'type == "array"' "trả về một mảng" || fail=1

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "✗ Smoke test FAILED — ít nhất một endpoint không đạt (HTTP 2xx + nội dung hợp lệ)."
  exit 1
fi

echo ""
echo "✓ Smoke test passed."

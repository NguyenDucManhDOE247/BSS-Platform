#!/usr/bin/env bash
# Kịch bản nghiệp vụ end-to-end bằng API, CÙNG một kịch bản cho mọi môi trường:
#
#   ./scripts/e2e-flow.sh kind        # http://bss.localhost (ingress-nginx) — mặc định
#   ./scripts/e2e-flow.sh dev         # https://dev.bssplatform.dpdns.org  (ALB + cert ACM thật)
#   ./scripts/e2e-flow.sh staging     # https://staging.bssplatform.dpdns.org
#   ./scripts/e2e-flow.sh prod        # https://bssplatform.dpdns.org
#
# Luồng (ADR-008): khách MỚI tự tạo hồ sơ → bị chặn mua (422, chưa duyệt) → tự duyệt mình (403) → NHÂN VIÊN
# duyệt → khách mua (giá từ catalog, B-13) → hóa đơn VAT 10% của CHÍNH khách → phía admin thấy đúng khách
# (Active), đơn, hóa đơn và doanh thu tăng → admin đổi giá + ngừng bán gói → đơn cũ giữ giá cũ → khách KHÁC
# đọc đơn/hóa đơn đó → 404. Luồng bằng trình duyệt thật: scripts/e2e-browser.sh.
#
# Danh tính: mỗi lần chạy tạo 3 user Keycloak TẠM (khách mới, nhân viên admin, khách khác) qua Admin REST
# API rồi XÓA khi kết thúc — không dựa vào user mẫu (admin1/customer1 chỉ có ở kind), nên cùng chạy được
# trên AWS nơi realm không có user nào. Dữ liệu nghiệp vụ (hồ sơ, gói đã ngừng bán, đơn, hóa đơn) ở lại DB
# — chấp nhận vì staging/prod là ephemeral (ADR-006); tên có tiền tố `e2e-` để nhận ra.
# Trên AWS: Admin API + token đi qua `kubectl port-forward` (scripts/lib/keycloak.sh — /auth/admin không ra
# ALB); mọi lời gọi NGHIỆP VỤ đi qua https://<host> thật, nối thẳng ALB bằng `curl --connect-to` (giữ
# SNI/Host + kiểm cert thật — cùng lý do với smoke.sh: không phụ thuộc cache DNS âm của máy chạy).
#
# Kỷ luật B-52: `set -euo pipefail`, mọi bước là `curl -f` hoặc `fail "…"` rõ ràng — không `|| true`.
#
# Lịch sử: là `scripts/e2e-kind.sh` (GĐ2 → GĐ9) — tên cũ vẫn chạy được (gọi file này với `kind`).
set -euo pipefail

ENV="${1:-kind}"
# shellcheck source=lib/keycloak.sh
. "$(dirname "$0")/lib/keycloak.sh"

log()  { echo "→ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

command -v jq >/dev/null 2>&1 || fail "cần jq"
command -v openssl >/dev/null 2>&1 || fail "cần openssl (sinh mật khẩu cho user thử)"

BODY_FILE="$(mktemp)"
TEMP_USER_IDS=()
cleanup() {
  for id in "${TEMP_USER_IDS[@]+"${TEMP_USER_IDS[@]}"}"; do kc_delete_user "$id"; done
  kc_disconnect
  rm -f "$BODY_FILE"
}
trap cleanup EXIT

kc_connect "$ENV" || fail "không kết nối được Keycloak ($ENV)"
CURL_OPTS=()
if [ "$ENV" = "kind" ]; then
  BASE_URL="http://bss.localhost"
else
  ALB="$(kubectl --context "$KCTX" -n bss get ingress bss-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  HOST="$(kubectl --context "$KCTX" -n bss get ingress bss-ingress -o jsonpath='{.spec.rules[0].host}')"
  [ -n "$ALB" ] && [ -n "$HOST" ] || fail "Ingress chưa có ALB/host — CD đã deploy chưa? (kubectl -n bss describe ingress bss-ingress)"
  BASE_URL="https://$HOST"
  CURL_OPTS=(--connect-to "$HOST:443:$ALB:443")
fi
GATEWAY_URL="$BASE_URL/api"

# curl tới website/API (KHÔNG dùng cho Keycloak — lib tự gọi KC_URL)
api() { curl ${CURL_OPTS[@]+"${CURL_OPTS[@]}"} "$@"; }

# HTTP status của 1 request (body ghi vào $BODY_FILE) — cho các bước MONG ĐỢI lỗi (401/403/404/422).
status_of() { api -sS -o "$BODY_FILE" -w '%{http_code}' "$@"; }

expect_status() {
  local want="$1" what="$2"; shift 2
  local got; got=$(status_of "$@")
  [ "$got" = "$want" ] || fail "$what: mong đợi HTTP $want, nhận $got — body: $(head -c 300 "$BODY_FILE")"
  ok "$what → $got"
}

echo "══ E2E nghiệp vụ trên $ENV — $BASE_URL ══"

# ── 1. Mọi Pod trong bss phải Ready trước — curl đua với Pod đang khởi động chỉ là test chập chờn. ──
log "Chờ mọi Pod trong namespace bss Ready (tối đa 3 phút)…"
if ! kubectl --context "$KCTX" -n bss wait --for=condition=Ready pod --all --timeout=180s; then
  kubectl --context "$KCTX" -n bss get pods
  fail "không phải Pod nào cũng Ready — xem 'kubectl -n bss describe pod <tên>' / 'logs <tên>'"
fi
ok "all Pods Ready"
api -fsS -o /dev/null "$BASE_URL/" || fail "GET / không trả lời — Ingress/ALB chưa sẵn sàng"
ok "website trả lời ở $BASE_URL"

# ── 2. Auth thật sự bật: không token → 401 ────────────────────────────────────────────────────
expect_status 401 "POST đơn hàng KHÔNG có token" -X POST "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder" \
  -H 'Content-Type: application/json' -d '{"items":[]}'

# ── 3. 3 user TẠM cho lần chạy này ────────────────────────────────────────────────────────────
kc_master_login || fail "không đăng nhập được Keycloak master"
RUN_ID="$(date +%s)-$$"
NEW_USER="e2e-cust-$RUN_ID";  NEW_PASS="$(kc_random_password)"
ADMIN_USER="e2e-staff-$RUN_ID"; ADMIN_PASS="$(kc_random_password)"
OTHER_USER="e2e-other-$RUN_ID"; OTHER_PASS="$(kc_random_password)"
log "Tạo 3 user Keycloak tạm (xóa khi kết thúc)…"
for u in "$NEW_USER:$NEW_PASS" "$ADMIN_USER:$ADMIN_PASS" "$OTHER_USER:$OTHER_PASS"; do
  id="$(kc_create_user "${u%%:*}" "${u%%:*}@example.com" "${u#*:}" false)"
  [ -n "$id" ] || fail "tạo user ${u%%:*} thất bại"
  TEMP_USER_IDS+=("$id")
done
kc_make_staff "${TEMP_USER_IDS[1]}"   # nhân viên: role admin, không phải khách hàng
ok "khách $NEW_USER · nhân viên $ADMIN_USER (role admin) · khách khác $OTHER_USER"

AS_CUSTOMER=(-H "Authorization: Bearer $(kc_user_token "$NEW_USER" "$NEW_PASS")")
AS_ADMIN=(-H "Authorization: Bearer $(kc_user_token "$ADMIN_USER" "$ADMIN_PASS")")
AS_OTHER=(-H "Authorization: Bearer $(kc_user_token "$OTHER_USER" "$OTHER_PASS")")

expect_status 403 "nhân viên (không có role customer) đặt hàng" -X POST "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder" \
  "${AS_ADMIN[@]}" -H 'Content-Type: application/json' -d '{"items":[]}'
SUMMARY_BEFORE=$(api -fsS "$GATEWAY_URL/tmf-api/billingManagement/v4/customerBill/summary" "${AS_ADMIN[@]}")

# ── 4. Luồng nghiệp vụ, đúng thứ tự khách thật trải qua ─────────────────────────────────────────
log "Khách tự tạo hồ sơ (POST /customer/me — email lấy từ token, không từ body)…"
CUSTOMER_JSON=$(api -fsS -X POST "$GATEWAY_URL/tmf-api/customerManagement/v4/customer/me" "${AS_CUSTOMER[@]}" \
  -H 'Content-Type: application/json' -d '{"name":"E2E Test","phoneNumber":"0900000000"}')
CUSTOMER_ID=$(echo "$CUSTOMER_JSON" | jq -r '.id')
CUSTOMER_STATUS=$(echo "$CUSTOMER_JSON" | jq -r '.status')
[ -n "$CUSTOMER_ID" ] && [ "$CUSTOMER_ID" != "null" ] || fail "tạo hồ sơ không trả id: $CUSTOMER_JSON"
[ "$CUSTOMER_STATUS" = "Initialized" ] || fail "hồ sơ mới phải là Initialized (chờ duyệt), nhận $CUSTOMER_STATUS"
ok "profile created: $CUSTOMER_ID (status=Initialized)"

# Gói RIÊNG cho lần chạy này (admin tạo): bước cuối đổi giá + ngừng bán nó, không đụng catalog seed.
log "Admin tạo gói riêng cho lần chạy này…"
OFFERING_JSON=$(api -fsS -X POST "$GATEWAY_URL/tmf-api/productCatalog/v4/productOffering" "${AS_ADMIN[@]}" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"E2E $ENV $RUN_ID\",\"priceAmount\":123000,\"priceCurrency\":\"VND\",\"recurringPeriod\":\"monthly\"}")
OFFERING_ID=$(echo "$OFFERING_JSON" | jq -r '.id')
[ -n "$OFFERING_ID" ] && [ "$OFFERING_ID" != "null" ] || fail "admin tạo gói thất bại: $OFFERING_JSON"

log "Khách xem gói (công khai, không cần token)…"
OFFERING_PRICE=$(api -fsS "$GATEWAY_URL/tmf-api/productCatalog/v4/productOffering/$OFFERING_ID" | jq -r '.priceAmount')
[ "$OFFERING_PRICE" != "null" ] || fail "không đọc được gói $OFFERING_ID khi chưa đăng nhập"
ok "offering $OFFERING_ID (price=$OFFERING_PRICE)"

# Không gửi customerId/giá: server lấy khách từ token (ADR-008) và giá từ catalog (B-13).
ORDER_BODY="{\"category\":\"new\",\"description\":\"e2e-$ENV\",\"items\":[{\"productOfferingId\":\"$OFFERING_ID\",\"quantity\":1}]}"
expect_status 422 "khách CHƯA duyệt đặt hàng" -X POST "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder" \
  "${AS_CUSTOMER[@]}" -H 'Content-Type: application/json' -d "$ORDER_BODY"

expect_status 403 "khách gọi API quản trị (duyệt chính mình)" -X PATCH \
  "$GATEWAY_URL/tmf-api/customerManagement/v4/customer/$CUSTOMER_ID" "${AS_CUSTOMER[@]}" \
  -H 'Content-Type: application/merge-patch+json' -d '{"status":"Active"}'

log "Admin thấy khách mới trong danh sách CHỜ DUYỆT (cái admin-console hiện ở trang Khách hàng)…"
api -fsS "$GATEWAY_URL/tmf-api/customerManagement/v4/customer?status=Initialized&q=$NEW_USER&limit=20" "${AS_ADMIN[@]}" \
  | jq -e --arg id "$CUSTOMER_ID" 'any(.[]; .id == $id)' >/dev/null || fail "admin không thấy khách mới ở danh sách chờ duyệt"
ok "admin thấy $NEW_USER ở trạng thái chờ duyệt"

log "Admin duyệt khách (Initialized → Active)…"
api -fsS -o /dev/null -X PATCH "$GATEWAY_URL/tmf-api/customerManagement/v4/customer/$CUSTOMER_ID" "${AS_ADMIN[@]}" \
  -H 'Content-Type: application/merge-patch+json' -d '{"status":"Active"}'
[ "$(api -fsS "$GATEWAY_URL/tmf-api/customerManagement/v4/customer/me" "${AS_CUSTOMER[@]}" | jq -r '.status')" = "Active" ] \
  || fail "khách vẫn chưa thấy mình Active sau khi admin duyệt"
ok "approved by $ADMIN_USER — khách thấy hồ sơ của mình là Active"

log "Khách đặt hàng (client KHÔNG gửi giá — B-13)…"
ORDER_JSON=$(api -fsS -X POST "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder" "${AS_CUSTOMER[@]}" \
  -H 'Content-Type: application/json' -d "$ORDER_BODY")
ORDER_ID=$(echo "$ORDER_JSON" | jq -r '.id')
ORDER_TOTAL=$(echo "$ORDER_JSON" | jq -r '.totalAmount')
ORDER_CUSTOMER=$(echo "$ORDER_JSON" | jq -r '.customerId')
[ -n "$ORDER_ID" ] && [ "$ORDER_ID" != "null" ] || fail "order creation failed: $ORDER_JSON"
[ "$ORDER_TOTAL" = "$OFFERING_PRICE" ] || fail "order total ($ORDER_TOTAL) != catalog price ($OFFERING_PRICE)"
[ "$ORDER_CUSTOMER" = "$CUSTOMER_ID" ] || fail "đơn gắn khách $ORDER_CUSTOMER, không phải người đăng nhập $CUSTOMER_ID"
ok "order created: $ORDER_ID (total=$ORDER_TOTAL = catalog price, customer = người đăng nhập)"

log "Chờ hóa đơn (outbox → EventBridge → SQS → billing-service)…"
INVOICE_JSON=""
for _ in $(seq 1 30); do
  # Khách chỉ thấy hóa đơn của chính mình → không cần (và không được) truyền customerId.
  RESP=$(api -fsS "$GATEWAY_URL/tmf-api/billingManagement/v4/customerBill?limit=10" "${AS_CUSTOMER[@]}")
  INVOICE_JSON=$(echo "$RESP" | jq -c --arg o "$ORDER_ID" '[.[] | select(any(.items[]; .sourceOrderId == $o))] | first // empty')
  [ -n "$INVOICE_JSON" ] && break
  sleep 3
done
[ -n "$INVOICE_JSON" ] || fail "không có hóa đơn sau 90s — xem 'kubectl -n bss logs deploy/billing-service' và 'deploy/order-management'"
INVOICE_ID=$(echo "$INVOICE_JSON" | jq -r '.id')
INVOICE_AMOUNT=$(echo "$INVOICE_JSON" | jq -r '.amount')
INVOICE_TAX=$(echo "$INVOICE_JSON" | jq -r '.taxAmount')
EXPECTED_TAX=$(awk -v p="$OFFERING_PRICE" 'BEGIN { printf "%.2f", p * 0.10 }')
[ "$(awk -v a="$INVOICE_TAX" -v b="$EXPECTED_TAX" 'BEGIN{print (a==b)}')" = "1" ] \
  || fail "invoice VAT ($INVOICE_TAX) != expected 10% of $OFFERING_PRICE ($EXPECTED_TAX)"
ok "invoice $(echo "$INVOICE_JSON" | jq -r '.invoiceNumber') đúng VAT: tax=$INVOICE_TAX, tổng=$INVOICE_AMOUNT"

# ── 5. Phía ADMIN thấy đúng những gì khách vừa làm (admin-console đọc đúng các API này) ────────────
expect_status 200 "admin đọc đơn của khách" "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder/$ORDER_ID" "${AS_ADMIN[@]}"
expect_status 200 "admin đọc hóa đơn của khách" "$GATEWAY_URL/tmf-api/billingManagement/v4/customerBill/$INVOICE_ID" "${AS_ADMIN[@]}"
SUMMARY_AFTER=$(api -fsS "$GATEWAY_URL/tmf-api/billingManagement/v4/customerBill/summary" "${AS_ADMIN[@]}")
jq -e -n --argjson b "$SUMMARY_BEFORE" --argjson a "$SUMMARY_AFTER" --arg amt "$INVOICE_AMOUNT" \
  '($a.invoiceCount >= $b.invoiceCount + 1) and (($a.totalAmount - $b.totalAmount) >= ($amt | tonumber))' >/dev/null \
  || fail "doanh thu admin không tăng theo hóa đơn mới: trước $SUMMARY_BEFORE, sau $SUMMARY_AFTER"
ok "doanh thu admin: $(echo "$SUMMARY_BEFORE" | jq -r .totalAmount) → $(echo "$SUMMARY_AFTER" | jq -r .totalAmount) (+ hóa đơn $INVOICE_AMOUNT)"

# ── 6. Admin đổi giá + ngừng bán gói → khách không thấy gói nữa, nhưng ĐƠN CŨ giữ giá lúc mua ─────
api -fsS -o /dev/null -X PATCH "$GATEWAY_URL/tmf-api/productCatalog/v4/productOffering/$OFFERING_ID" "${AS_ADMIN[@]}" \
  -H 'Content-Type: application/merge-patch+json' -d '{"priceAmount":150000,"lifecycleStatus":"Retired"}'
ok "admin đổi giá gói → 150000 và ngừng bán (Retired)"
api -fsS "$GATEWAY_URL/tmf-api/productCatalog/v4/productOffering?lifecycleStatus=Active&limit=100" \
  | jq -e --arg id "$OFFERING_ID" 'all(.[]; .id != $id)' >/dev/null || fail "gói đã ngừng bán vẫn hiện trong danh sách gói đang bán"
ok "gói đã ngừng bán không còn trong danh sách khách thấy"
OLD_ORDER=$(api -fsS "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder/$ORDER_ID" "${AS_CUSTOMER[@]}")
[ "$(echo "$OLD_ORDER" | jq -r '.items[0].unitPrice')" = "$OFFERING_PRICE" ] \
  && [ "$(echo "$OLD_ORDER" | jq -r '.totalAmount')" = "$OFFERING_PRICE" ] || fail "đơn cũ bị đổi giá theo catalog: $OLD_ORDER"
ok "đơn cũ vẫn giữ giá lúc mua ($OFFERING_PRICE), không theo giá mới"

# ── 7. Quyền sở hữu: khách KHÁC không đọc được đơn/hóa đơn này (404 — không lộ là nó tồn tại) ─────
expect_status 404 "khách khác đọc đơn của khách này" "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder/$ORDER_ID" "${AS_OTHER[@]}"
expect_status 404 "khách khác đọc hóa đơn của khách này" "$GATEWAY_URL/tmf-api/billingManagement/v4/customerBill/$INVOICE_ID" "${AS_OTHER[@]}"
expect_status 403 "khách gọi API quản trị (liệt kê khách)" "$GATEWAY_URL/tmf-api/customerManagement/v4/customer" "${AS_OTHER[@]}"

echo ""
ok "ALL CHECKS PASSED ($ENV) — đăng ký → chờ duyệt → nhân viên duyệt → mua → hóa đơn → admin thấy đúng (+ quyền sở hữu)."

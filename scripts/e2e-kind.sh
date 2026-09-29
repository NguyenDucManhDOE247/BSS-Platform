#!/usr/bin/env bash
# End-to-end smoke test for the *kind* stack — same business flow as scripts/e2e-local.sh
# (customer → plans → order → invoice) but through the real Ingress at http://bss.localhost
# instead of `mvn spring-boot:run` on bare metal. This is the Giai đoạn 2 equivalent checkpoint
# of Giai đoạn 1's e2e-local.sh — see learning/20 Giai đoạn 2 checkpoint.
#
# Giai đoạn 9 (ADR-008): overlay `local` BẬT auth (BSS_AUTH_ENABLED=true + Keycloak) → bản cũ của
# script này (gọi API không token, admin tự tạo khách hộ) chết ngay ở bước đầu với 401. Bản này đi
# đúng luồng thật bằng API, không cần trình duyệt (luồng trình duyệt: scripts/e2e-browser.sh):
#   khách MỚI (user Keycloak tạo riêng cho mỗi lần chạy) → tự tạo hồ sơ → bị chặn mua (422, chưa
#   duyệt) → admin1 duyệt → mua → thấy hóa đơn của CHÍNH mình (VAT 10%) → khách khác (customer1)
#   đọc đơn/hóa đơn đó → 404, gọi API quản trị → 403.
# e2e-local.sh KHÔNG cần đổi: service chạy bằng `mvn` với profile `local`, auth tắt (mặc định).
#
# Same B-52 discipline as e2e-local.sh: `set -euo pipefail`, every check is `curl -f` or an
# explicit `fail "..."` — nothing swallowed with `|| true` / `|| echo`.
#
# Prerequisites (see infrastructure/kubernetes/overlays/local/README.md):
#   ./scripts/kind-up.sh && ./scripts/auth-install.sh   # cluster + ingress + Secret keycloak-admin
#   docker build -t bss/<svc>:local ...                  # x7, then `kind load docker-image` x7
#   kubectl --context kind-bss apply -k infrastructure/kubernetes/overlays/local
#
# Usage: ./scripts/e2e-kind.sh
set -euo pipefail

KCTX="kind-bss"
BASE_URL="http://bss.localhost"
GATEWAY_URL="$BASE_URL/api"
REALM_URL="$BASE_URL/auth/realms/bss"
# 2 user thử có sẵn trong realm kind (overlays/local/keycloak/realm-bss.json) — chỉ tồn tại ở local.
ADMIN_USER="admin1";    ADMIN_PASS="admin1pass"
OTHER_USER="customer1"; OTHER_PASS="customer1pass"

log()  { echo "→ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

command -v jq >/dev/null 2>&1 || fail "cần jq"
command -v openssl >/dev/null 2>&1 || fail "cần openssl (sinh mật khẩu cho user thử)"

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

# HTTP status của 1 request (body ghi vào $BODY_FILE) — dùng cho các bước MONG ĐỢI lỗi (401/403/404/
# 422): `curl -f` sẽ coi đó là thất bại của script, trong khi ở đây chính mã lỗi đó mới là "PASS".
status_of() { curl -sS -o "$BODY_FILE" -w '%{http_code}' "$@"; }

expect_status() {
  local want="$1" what="$2"; shift 2
  local got; got=$(status_of "$@")
  [ "$got" = "$want" ] || fail "$what: mong đợi HTTP $want, nhận $got — body: $(head -c 300 "$BODY_FILE")"
  ok "$what → $got"
}

# Token người dùng qua password grant của client `api-gateway` (client DUY NHẤT bật Direct Access
# Grants — 2 SPA chỉ dùng Authorization Code + PKCE, xem ADR-008 quyết định 1).
user_token() {
  local tok
  tok=$(curl -fsS "$REALM_URL/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=api-gateway \
    --data-urlencode "username=$1" --data-urlencode "password=$2" | jq -r '.access_token')
  [ -n "$tok" ] && [ "$tok" != "null" ] || fail "không lấy được token cho $1"
  echo "$tok"
}

# ── 1. Every Pod in namespace bss must be Ready first — a curl racing a Pod that's still
#    starting (Flyway migrating, waiting on postgres DNS, etc.) would just be a flaky test. ────
log "Waiting for every Pod in namespace bss to be Ready (up to 3 min)…"
if ! kubectl --context "$KCTX" -n bss wait --for=condition=Ready pod --all --timeout=180s; then
  echo ""
  echo "── Pods that are not Ready — kubectl describe of each ──"
  kubectl --context "$KCTX" -n bss get pods
  fail "not every Pod became Ready — see 'kubectl -n bss describe pod <name>' / 'logs <name>' above"
fi
ok "all Pods Ready"

log "Sanity-checking the Ingress answers at all…"
curl -fsS -o /dev/null "$BASE_URL/" || fail "GET / through the Ingress failed — is ingress-nginx installed? (scripts/kind-up.sh)"
ok "Ingress responds"

# ── 2. Auth thật sự bật: không token → 401 ────────────────────────────────────────────────────
expect_status 401 "POST đơn hàng KHÔNG có token" -X POST "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder" \
  -H 'Content-Type: application/json' -d '{"items":[]}'

# ── 3. 1 khách MỚI mỗi lần chạy: tạo user Keycloak qua Admin REST API (tài khoản master lấy từ Secret
#    keycloak-admin do auth-install.sh tạo). Không dùng lại customer1: hồ sơ của nó đã Active từ lần
#    chạy trước → không kiểm được bước "chưa duyệt thì bị chặn". ──────────────────────────────────
RUN_ID="$(date +%s)-$$"
NEW_USER="e2e-kind-$RUN_ID"
NEW_PASS="$(openssl rand -base64 18 | tr -d '/+=')"
KC_ADMIN_PASS=$(kubectl --context "$KCTX" -n bss get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)
KC_MASTER_TOKEN=$(curl -fsS "$BASE_URL/auth/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d username=admin \
  --data-urlencode "password=$KC_ADMIN_PASS" | jq -r '.access_token')
[ -n "$KC_MASTER_TOKEN" ] && [ "$KC_MASTER_TOKEN" != "null" ] || fail "không đăng nhập được Keycloak master (Secret keycloak-admin?)"
log "Tạo user Keycloak $NEW_USER (role mặc định của realm: customer)…"
jq -n --arg u "$NEW_USER" --arg p "$NEW_PASS" '{
  username: $u, email: ($u + "@example.com"), firstName: "E2E", lastName: "Kind",
  enabled: true, emailVerified: true,
  credentials: [{ type: "password", value: $p, temporary: false }]
}' | curl -fsS -X POST "$BASE_URL/auth/admin/realms/bss/users" \
  -H "Authorization: Bearer $KC_MASTER_TOKEN" -H 'Content-Type: application/json' -d @- \
  || fail "tạo user Keycloak thất bại"
ok "user $NEW_USER created"

CUSTOMER_TOKEN=$(user_token "$NEW_USER" "$NEW_PASS")
ADMIN_TOKEN=$(user_token "$ADMIN_USER" "$ADMIN_PASS")
OTHER_TOKEN=$(user_token "$OTHER_USER" "$OTHER_PASS")
AS_CUSTOMER=(-H "Authorization: Bearer $CUSTOMER_TOKEN")
AS_ADMIN=(-H "Authorization: Bearer $ADMIN_TOKEN")
AS_OTHER=(-H "Authorization: Bearer $OTHER_TOKEN")

# ── 4. Business flow, đúng thứ tự khách thật trải qua ─────────────────────────────────────────
log "Khách tự tạo hồ sơ (POST /customer/me — email lấy từ token, không từ body)…"
CUSTOMER_JSON=$(curl -fsS -X POST "$GATEWAY_URL/tmf-api/customerManagement/v4/customer/me" "${AS_CUSTOMER[@]}" \
  -H 'Content-Type: application/json' -d '{"name":"E2E Kind Test","phoneNumber":"0900000000"}')
CUSTOMER_ID=$(echo "$CUSTOMER_JSON" | jq -r '.id')
CUSTOMER_STATUS=$(echo "$CUSTOMER_JSON" | jq -r '.status')
[ -n "$CUSTOMER_ID" ] && [ "$CUSTOMER_ID" != "null" ] || fail "tạo hồ sơ không trả id: $CUSTOMER_JSON"
[ "$CUSTOMER_STATUS" = "Initialized" ] || fail "hồ sơ mới phải là Initialized (chờ duyệt), nhận $CUSTOMER_STATUS"
ok "profile created: $CUSTOMER_ID (status=Initialized)"

log "Listing product offerings (công khai, không cần token)…"
OFFERINGS_JSON=$(curl -fsS "$GATEWAY_URL/tmf-api/productCatalog/v4/productOffering?lifecycleStatus=Active&limit=10")
OFFERING_ID=$(echo "$OFFERINGS_JSON" | jq -r '.[0].id')
OFFERING_PRICE=$(echo "$OFFERINGS_JSON" | jq -r '.[0].priceAmount')
[ -n "$OFFERING_ID" ] && [ "$OFFERING_ID" != "null" ] || fail "no product offerings found — did Flyway seed data run?"
ok "found offering $OFFERING_ID (price=$OFFERING_PRICE)"

# Không gửi customerId/giá: server lấy khách từ token (ADR-008) và giá từ catalog (B-13).
ORDER_BODY="{\"category\":\"new\",\"description\":\"e2e-kind\",\"items\":[{\"productOfferingId\":\"$OFFERING_ID\",\"quantity\":1}]}"
expect_status 422 "khách CHƯA duyệt đặt hàng" -X POST "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder" \
  "${AS_CUSTOMER[@]}" -H 'Content-Type: application/json' -d "$ORDER_BODY"

expect_status 403 "khách gọi API quản trị (duyệt chính mình)" -X PATCH \
  "$GATEWAY_URL/tmf-api/customerManagement/v4/customer/$CUSTOMER_ID" "${AS_CUSTOMER[@]}" \
  -H 'Content-Type: application/merge-patch+json' -d '{"status":"Active"}'

log "Admin duyệt khách (Initialized → Active)…"
curl -fsS -o /dev/null -X PATCH "$GATEWAY_URL/tmf-api/customerManagement/v4/customer/$CUSTOMER_ID" "${AS_ADMIN[@]}" \
  -H 'Content-Type: application/merge-patch+json' -d '{"status":"Active"}'
ok "approved by $ADMIN_USER"

log "Placing an order (price is NOT sent by the client — see B-13)…"
ORDER_JSON=$(curl -fsS -X POST "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder" "${AS_CUSTOMER[@]}" \
  -H 'Content-Type: application/json' -d "$ORDER_BODY")
ORDER_ID=$(echo "$ORDER_JSON" | jq -r '.id')
ORDER_TOTAL=$(echo "$ORDER_JSON" | jq -r '.totalAmount')
ORDER_CUSTOMER=$(echo "$ORDER_JSON" | jq -r '.customerId')
[ -n "$ORDER_ID" ] && [ "$ORDER_ID" != "null" ] || fail "order creation failed: $ORDER_JSON"
[ "$ORDER_TOTAL" = "$OFFERING_PRICE" ] || fail "order total ($ORDER_TOTAL) != catalog price ($OFFERING_PRICE)"
[ "$ORDER_CUSTOMER" = "$CUSTOMER_ID" ] || fail "đơn gắn khách $ORDER_CUSTOMER, không phải người đăng nhập $CUSTOMER_ID"
ok "order created: $ORDER_ID (total=$ORDER_TOTAL = catalog price, customer = người đăng nhập)"

log "Polling for the invoice (outbox drainer → EventBridge(LocalStack) → SQS → billing-service)…"
INVOICE_JSON=""
for _ in $(seq 1 30); do
  # Khách chỉ thấy hóa đơn của chính mình → không cần (và không được) truyền customerId.
  RESP=$(curl -fsS "$GATEWAY_URL/tmf-api/billingManagement/v4/customerBill?limit=10" "${AS_CUSTOMER[@]}")
  INVOICE_JSON=$(echo "$RESP" | jq -c --arg o "$ORDER_ID" '[.[] | select(any(.items[]; .sourceOrderId == $o))] | first // empty')
  [ -n "$INVOICE_JSON" ] && break
  sleep 3
done
[ -n "$INVOICE_JSON" ] || fail "no invoice appeared within 90s — check 'kubectl -n bss logs deploy/billing-service' and 'deploy/order-management'"
INVOICE_ID=$(echo "$INVOICE_JSON" | jq -r '.id')

INVOICE_TAX=$(echo "$INVOICE_JSON" | jq -r '.taxAmount')
EXPECTED_TAX=$(awk -v p="$OFFERING_PRICE" 'BEGIN { printf "%.2f", p * 0.10 }')
[ "$(awk -v a="$INVOICE_TAX" -v b="$EXPECTED_TAX" 'BEGIN{print (a==b)}')" = "1" ] \
  || fail "invoice VAT ($INVOICE_TAX) != expected 10% of $OFFERING_PRICE ($EXPECTED_TAX)"
ok "invoice $(echo "$INVOICE_JSON" | jq -r '.invoiceNumber') found with correct VAT: tax=$INVOICE_TAX (expected $EXPECTED_TAX)"

# ── 5. Quyền sở hữu: khách KHÁC không đọc được đơn/hóa đơn này (404 — không lộ là nó tồn tại) ─────
expect_status 404 "$OTHER_USER đọc đơn của khách khác" "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder/$ORDER_ID" "${AS_OTHER[@]}"
expect_status 404 "$OTHER_USER đọc hóa đơn của khách khác" "$GATEWAY_URL/tmf-api/billingManagement/v4/customerBill/$INVOICE_ID" "${AS_OTHER[@]}"
expect_status 200 "admin đọc hóa đơn đó" "$GATEWAY_URL/tmf-api/billingManagement/v4/customerBill/$INVOICE_ID" "${AS_ADMIN[@]}"

echo ""
ok "ALL CHECKS PASSED — đăng ký → chờ duyệt → admin duyệt → order → invoice (+ quyền sở hữu) end-to-end through kind + ingress-nginx + Keycloak."

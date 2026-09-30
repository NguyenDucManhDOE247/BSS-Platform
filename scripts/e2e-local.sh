#!/usr/bin/env bash
# End-to-end smoke test for the *local* stack: customer → plans → order → invoice, all through
# the API gateway, exactly like a real browser session would.
#
# 2026-09-30 (ADR-008 quyết định 6): auth LUÔN bật — công tắc `bss.auth.enabled` đã xóa. Script đi
# đúng luồng thật bằng token Keycloak của docker-compose (localhost:8180): tạo 1 user Keycloak MỚI mỗi
# lần chạy → tự tạo hồ sơ → bị chặn mua (422, chưa duyệt) → admin1 duyệt → mua → hóa đơn của chính
# mình (VAT 10%) → customer1 đọc hóa đơn đó → 404. Cùng mô hình với scripts/e2e-kind.sh.
#
# B-52 groundwork: scripts/smoke.sh (the AWS/EKS version) is written so it can NEVER fail —
# `curl ... | jq . || echo "  failed"` always exits 0 because the last command in that
# pipeline is `echo`, which always succeeds. A CD pipeline built on a smoke test that can't
# fail cannot roll back on a bad deploy; see learning/01 B-52 and B-50/B-51. This script is
# built the opposite way on purpose, as the pattern to carry over when B-52 itself gets fixed
# in Giai đoạn 5-6:
#   - `set -euo pipefail` so an unexpected error stops the script instead of limping on.
#   - every check either uses `curl -f` (fails the whole `set -e` script on a non-2xx
#     response) or an explicit `fail "message"` that prints *why* and exits 1 — nothing is
#     silently swallowed with `|| true` / `|| echo`.
#
# Usage:
#   ./scripts/e2e-local.sh              # fresh run: docker compose down -v, then up + test
#   ./scripts/e2e-local.sh --keep-stack # skip the down -v / up — reuse whatever is running
#   ./scripts/e2e-local.sh --stay-up    # after the checks pass, leave everything running so
#                                       # you can point a browser (npm run dev) at a real,
#                                       # already-populated backend instead of tearing it all
#                                       # down immediately. Press Ctrl+C here when you're done —
#                                       # that still runs the same cleanup as a normal exit.
#   (flags can be combined, e.g. --keep-stack --stay-up)
#
# Requires (see learning/00 + docs/adr/ADR-000-local-dev.md): docker, mvn, curl, jq, openssl, and the 5
# backend services buildable with `mvn -B package -DskipTests` (already verified once by
# `mvn -B verify`, per Giai đoạn 1 step 1).
#
# A note on *why* this script starts every service with `(cd "$dir" && cmd &)` instead of a
# plain `cd "$dir" && cmd &` typed one-per-line into an interactive shell: backgrounding a
# `&&` chain with a trailing `&` still runs the WHOLE chain (including the `cd`) as one job,
# but that job gets its own subshell for job control — the `cd` inside it does NOT change the
# directory of the shell you're typing into. Paste several `cd ../next-service && ... &` lines
# in a row expecting them to chain off each other's `cd` and every one after the first fails
# with "No such file or directory", because the interactive shell's own cwd never moved. The
# parentheses `(...)` here make the subshell explicit and self-contained (an absolute path in,
# nothing leaks out) instead of relying on relative `cd`s across commands.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$ROOT_DIR/deploy"
LOG_DIR="$ROOT_DIR/.e2e-local-logs"
GATEWAY_URL="http://localhost:8080"
KEEP_STACK=0
STAY_UP=0
for arg in "$@"; do
  case "$arg" in
    --keep-stack) KEEP_STACK=1 ;;
    --stay-up) STAY_UP=1 ;;
    *) echo "Unknown flag: $arg (expected --keep-stack and/or --stay-up)" >&2; exit 2 ;;
  esac
done

PIDS=()

log()  { echo "→ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

cleanup() {
  local status=$?
  # Mỗi service chạy trong PROCESS GROUP riêng (setsid ở start_service) → `kill -- -PGID` giết cả nhóm:
  # wrapper /usr/bin/mvn + JVM của Maven + JVM app mà spring-boot:run fork ra. Giết mỗi PID của `$!`
  # (như bản cũ) chỉ giết wrapper — Maven + app thành MỒ CÔI, giữ cổng 8080–8084 (lỗi thật 2026-09-30).
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" >/dev/null 2>&1 || true
  done
  sleep 2
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" >/dev/null 2>&1 || true
  done
  if [ "$status" -ne 0 ]; then
    echo ""
    echo "── Last 30 lines of each service log (see $LOG_DIR for the full thing) ──"
    for f in "$LOG_DIR"/*.log; do
      [ -f "$f" ] || continue
      echo "--- $f ---"
      tail -n 30 "$f" || true
    done
  fi
  exit "$status"
}
trap cleanup EXIT

mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.log

# ── 1. Local infrastructure ────────────────────────────────────────────────
if [ "$KEEP_STACK" -eq 0 ]; then
  log "docker compose down -v (clean slate — this is the checkpoint's starting state)"
  (cd "$DEPLOY_DIR" && docker compose down -v)
  log "docker compose up -d (postgres + redis + localstack + keycloak)"
  (cd "$DEPLOY_DIR" && docker compose up -d)
else
  log "--keep-stack: reusing whatever docker compose stack is already running"
fi

log "Waiting for postgres to be healthy…"
for _ in $(seq 1 30); do
  status=$(docker inspect -f '{{.State.Health.Status}}' bss-postgres 2>/dev/null || echo "starting")
  [ "$status" = "healthy" ] && break
  sleep 2
done
[ "$status" = "healthy" ] || fail "postgres never became healthy (docker inspect bss-postgres)"
ok "postgres healthy"

log "Waiting for localstack to be healthy…"
for _ in $(seq 1 30); do
  status=$(docker inspect -f '{{.State.Health.Status}}' bss-localstack 2>/dev/null || echo "starting")
  [ "$status" = "healthy" ] && break
  sleep 2
done
[ "$status" = "healthy" ] || fail "localstack never became healthy (docker inspect bss-localstack)"
ok "localstack healthy"

log "Waiting for keycloak to be healthy (realm bss + 2 test users imported)…"
for _ in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' bss-keycloak 2>/dev/null || echo "starting")
  [ "$status" = "healthy" ] && break
  sleep 2
done
[ "$status" = "healthy" ] || fail "keycloak never became healthy (docker logs bss-keycloak)"
ok "keycloak healthy"

# ── 2. Backend services (SPRING_PROFILES_ACTIVE=local — see application-local.yml per service) ──
set -a
# shellcheck disable=SC1091
source "$DEPLOY_DIR/.env.example"
set +a
export SPRING_PROFILES_ACTIVE=local

start_service() {
  local name="$1" dir="$2" port="$3"
  log "Starting $name on :$port (log: $LOG_DIR/$name.log)"
  # No -o (offline): whenever a pom.xml version changes (e.g. a dependency bump), Maven needs
  # to resolve new artifacts from Maven Central first — offline mode would just fail with
  # "artifact has not been downloaded before" instead of fetching it. First run of the day
  # will be a bit slower; every run after that is fast because ~/.m2 is warm.
  #
  # Orphan JVMs — the bug this block exists for. `spring-boot:run` FORKS a second JVM for the app
  # (Spring Boot 3's plugin has no `fork=false` any more — the flag this script used to pass was
  # silently ignored), and `/usr/bin/mvn` is itself a bash wrapper around Maven's JVM. So `$!` is
  # 3 processes away from the app. Killing just `$!` left Maven + app alive, still bound to
  # 8080–8084; the NEXT run's services then failed to start ("Port already in use"), health checks
  # were answered by the stale JVMs, and API calls hit a database that `down -v` had just wiped →
  # HTTP 500 (found for real 2026-09-30, running the checkpoint from a clean clone).
  # Fix: `setsid` makes each service the leader of its OWN process group (PGID = the PID we save),
  # and cleanup() kills the whole group. The background subshell is not a group leader (no job
  # control in a script), so setsid execs in place and keeps that PID.
  ( cd "$ROOT_DIR/apps/backend/$dir" && exec setsid mvn -q spring-boot:run > "$LOG_DIR/$name.log" 2>&1 ) &
  echo $! > "$LOG_DIR/$name.pid"
  PIDS+=("$!")
}

wait_healthy() {
  local name="$1" port="$2"
  log "Waiting for $name health endpoint (localhost:$port)…"
  for _ in $(seq 1 60); do
    if curl -fsS "http://localhost:$port/actuator/health" 2>/dev/null | grep -q '"status":"UP"'; then
      ok "$name is UP"
      return 0
    fi
    sleep 3
  done
  fail "$name never reported UP on :$port — see $LOG_DIR/$name.log"
}

command -v setsid >/dev/null 2>&1 || fail "setsid is required (util-linux) — run this in Linux/WSL"
# A port still taken means a JVM from an earlier run survived — fail loudly instead of letting the
# health checks below be answered by that stale process (see the long comment in start_service).
for port in 8080 8081 8082 8083 8084; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    fail "port $port is already in use — a backend from a previous run is still alive? (ss -ltnp | grep :$port)"
  fi
done

start_service customer-service customer-service 8081
start_service product-catalog  product-catalog  8082
start_service order-management order-management 8083
start_service billing-service  billing-service  8084
start_service api-gateway      api-gateway      8080

wait_healthy customer-service 8081
wait_healthy product-catalog  8082
wait_healthy order-management 8083
wait_healthy billing-service  8084
wait_healthy api-gateway      8080

# ── 3. The actual business flow, through the gateway, exactly like the UI does ──────────────
# Token thật từ Keycloak của docker-compose (KC_HOSTNAME=http://localhost:8180/auth → `iss` khớp đúng
# issuer-uri trong application-local.yml của 5 service).
REALM_URL="http://localhost:8180/auth/realms/bss"
BODY_FILE="$(mktemp)"
status_of() { curl -sS -o "$BODY_FILE" -w '%{http_code}' "$@"; }
expect_status() {
  local want="$1" what="$2"; shift 2
  local got; got=$(status_of "$@")
  [ "$got" = "$want" ] || fail "$what: expected HTTP $want, got $got — body: $(head -c 300 "$BODY_FILE")"
  ok "$what → $got"
}
# Password grant qua client `api-gateway` — client DUY NHẤT bật Direct Access Grants (chỉ cho script/test;
# 2 website dùng Authorization Code + PKCE — ADR-008 quyết định 1).
user_token() {
  local tok
  tok=$(curl -fsS "$REALM_URL/protocol/openid-connect/token" -d grant_type=password -d client_id=api-gateway \
    --data-urlencode "username=$1" --data-urlencode "password=$2" | jq -r '.access_token')
  [ -n "$tok" ] && [ "$tok" != "null" ] || fail "could not get a token for $1"
  echo "$tok"
}

command -v openssl >/dev/null 2>&1 || fail "openssl is required (random password for the test user)"

expect_status 401 "POST order WITHOUT a token" -X POST "$GATEWAY_URL/api/tmf-api/orderManagement/v4/productOrder" \
  -H 'Content-Type: application/json' -d '{"items":[]}'

# Unique user per run: --keep-stack reuses Keycloak + Postgres, and the "not approved yet → 422" check
# needs a customer whose profile is brand new.
RUN_ID="$(date +%s)-$$"
NEW_USER="e2e-local-$RUN_ID"
NEW_PASS="$(openssl rand -base64 18 | tr -d '/+=')"
# admin/admin of the compose Keycloak master realm — local-only, same "not a secret" level as bss/bss
# for Postgres (see deploy/docker-compose.yml).
KC_MASTER_TOKEN=$(curl -fsS "http://localhost:8180/auth/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin | jq -r '.access_token')
[ -n "$KC_MASTER_TOKEN" ] && [ "$KC_MASTER_TOKEN" != "null" ] || fail "could not log in to the Keycloak master realm"
log "Creating Keycloak user $NEW_USER (realm default role: customer)…"
jq -n --arg u "$NEW_USER" --arg p "$NEW_PASS" '{
  username: $u, email: ($u + "@example.com"), firstName: "E2E", lastName: "Local",
  enabled: true, emailVerified: true,
  credentials: [{ type: "password", value: $p, temporary: false }]
}' | curl -fsS -X POST "http://localhost:8180/auth/admin/realms/bss/users" \
  -H "Authorization: Bearer $KC_MASTER_TOKEN" -H 'Content-Type: application/json' -d @- \
  || fail "creating the Keycloak user failed"
ok "user $NEW_USER created"

AS_CUSTOMER=(-H "Authorization: Bearer $(user_token "$NEW_USER" "$NEW_PASS")")
AS_ADMIN=(-H "Authorization: Bearer $(user_token admin1 admin1pass)")
AS_OTHER=(-H "Authorization: Bearer $(user_token customer1 customer1pass)")

log "Customer creates their own profile (POST /customer/me — email comes from the token)…"
CUSTOMER_JSON=$(curl -fsS -X POST "$GATEWAY_URL/api/tmf-api/customerManagement/v4/customer/me" "${AS_CUSTOMER[@]}" \
  -H 'Content-Type: application/json' -d '{"name":"E2E Local Test"}')
CUSTOMER_ID=$(echo "$CUSTOMER_JSON" | jq -r '.id')
[ -n "$CUSTOMER_ID" ] && [ "$CUSTOMER_ID" != "null" ] || fail "profile creation didn't return an id: $CUSTOMER_JSON"
[ "$(echo "$CUSTOMER_JSON" | jq -r '.status')" = "Initialized" ] || fail "a new profile must be Initialized: $CUSTOMER_JSON"
ok "profile created: $CUSTOMER_ID (status=Initialized — waiting for approval)"

log "Listing product offerings (public, no token; Flyway seed data)…"
OFFERINGS_JSON=$(curl -fsS "$GATEWAY_URL/api/tmf-api/productCatalog/v4/productOffering?lifecycleStatus=Active&limit=10")
OFFERING_ID=$(echo "$OFFERINGS_JSON" | jq -r '.[0].id')
OFFERING_PRICE=$(echo "$OFFERINGS_JSON" | jq -r '.[0].priceAmount')
[ -n "$OFFERING_ID" ] && [ "$OFFERING_ID" != "null" ] || fail "no product offerings found — did Flyway seed data run?"
ok "found offering $OFFERING_ID (price=$OFFERING_PRICE)"

# No customerId, no price: the customer is whoever the token says (ADR-008), the price comes from
# product-catalog (B-13).
ORDER_BODY="{\"category\":\"new\",\"description\":\"e2e-local\",\"items\":[{\"productOfferingId\":\"$OFFERING_ID\",\"quantity\":1}]}"
expect_status 422 "order by a NOT-yet-approved customer" -X POST "$GATEWAY_URL/api/tmf-api/orderManagement/v4/productOrder" \
  "${AS_CUSTOMER[@]}" -H 'Content-Type: application/json' -d "$ORDER_BODY"

log "Admin approves the customer (Initialized → Active)…"
curl -fsS -o /dev/null -X PATCH "$GATEWAY_URL/api/tmf-api/customerManagement/v4/customer/$CUSTOMER_ID" "${AS_ADMIN[@]}" \
  -H 'Content-Type: application/merge-patch+json' -d '{"status":"Active"}'
ok "approved by admin1"

log "Placing an order (price is NOT sent by the client — see B-13)…"
ORDER_JSON=$(curl -fsS -X POST "$GATEWAY_URL/api/tmf-api/orderManagement/v4/productOrder" "${AS_CUSTOMER[@]}" \
  -H 'Content-Type: application/json' -d "$ORDER_BODY")
ORDER_ID=$(echo "$ORDER_JSON" | jq -r '.id')
ORDER_TOTAL=$(echo "$ORDER_JSON" | jq -r '.totalAmount')
[ -n "$ORDER_ID" ] && [ "$ORDER_ID" != "null" ] || fail "order creation failed: $ORDER_JSON"
[ "$ORDER_TOTAL" = "$OFFERING_PRICE" ] || fail "order total ($ORDER_TOTAL) != catalog price ($OFFERING_PRICE) — price should come from product-catalog"
[ "$(echo "$ORDER_JSON" | jq -r '.customerId')" = "$CUSTOMER_ID" ] || fail "order is not attached to the signed-in customer: $ORDER_JSON"
ok "order created: $ORDER_ID (total=$ORDER_TOTAL, matches catalog price; customer = signed-in user)"

log "Polling for the invoice (outbox drainer → EventBridge → SQS → billing-service, every few seconds)…"
INVOICE_JSON=""
for _ in $(seq 1 30); do
  # A customer only ever sees their own bills — no customerId parameter needed (or honoured).
  RESP=$(curl -fsS "$GATEWAY_URL/api/tmf-api/billingManagement/v4/customerBill?limit=10" "${AS_CUSTOMER[@]}")
  INVOICE_JSON=$(echo "$RESP" | jq -c --arg o "$ORDER_ID" '[.[] | select(any(.items[]; .sourceOrderId == $o))] | first // empty')
  [ -n "$INVOICE_JSON" ] && break
  sleep 3
done
[ -n "$INVOICE_JSON" ] || fail "no invoice appeared within 90s — check billing-service.log and order-management.log for the outbox/SQS chain"

INVOICE_ID=$(echo "$INVOICE_JSON" | jq -r '.id')
INVOICE_AMOUNT=$(echo "$INVOICE_JSON" | jq -r '.amount')
INVOICE_TAX=$(echo "$INVOICE_JSON" | jq -r '.taxAmount')
EXPECTED_TAX=$(awk -v p="$OFFERING_PRICE" 'BEGIN { printf "%.2f", p * 0.10 }')
EXPECTED_TOTAL=$(awk -v p="$OFFERING_PRICE" -v t="$EXPECTED_TAX" 'BEGIN { printf "%.2f", p + t }')
[ "$(awk -v a="$INVOICE_TAX" -v b="$EXPECTED_TAX" 'BEGIN{print (a==b)}')" = "1" ] \
  || fail "invoice VAT ($INVOICE_TAX) != expected 10% of $OFFERING_PRICE ($EXPECTED_TAX)"
ok "invoice found with correct VAT: amount=$INVOICE_AMOUNT tax=$INVOICE_TAX (expected total ≈ $EXPECTED_TOTAL)"

expect_status 404 "customer1 reads someone else's invoice" \
  "$GATEWAY_URL/api/tmf-api/billingManagement/v4/customerBill/$INVOICE_ID" "${AS_OTHER[@]}"
rm -f "$BODY_FILE"

echo ""
ok "ALL CHECKS PASSED — sign-up → approval → order → invoice (+ ownership) end-to-end through the gateway + Keycloak."

if [ "$STAY_UP" -eq 1 ]; then
  echo ""
  log "--stay-up: leaving everything running so you can point a browser at a real backend."
  echo "   web-portal:    cd apps/frontend/web-portal   && npm install && npm run dev   → http://localhost:3000"
  echo "   admin-console: cd apps/frontend/admin-console && npm install && npm run dev   → http://localhost:3001"
  echo "   (run those in a SEPARATE terminal — this one needs to keep running)"
  echo "   Press Ctrl+C here when you're done: kills the 5 backend processes (verified — sends"
  echo "   SIGINT, cleanup() below runs). Postgres/LocalStack/Redis containers are left running"
  echo "   either way (same as every other run) — 'make local-down' or the next"
  echo "   ./scripts/e2e-local.sh (which starts with docker compose down -v) will stop those."
  sleep infinity
fi

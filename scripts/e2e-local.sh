#!/usr/bin/env bash
# End-to-end smoke test for the *local* stack: customer → plans → order → invoice, all through
# the API gateway, exactly like a real browser session would.
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
# Requires (see learning/00 + docs/adr/ADR-000-local-dev.md): docker, mvn, curl, jq, and the 5
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
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
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
  log "docker compose up -d (postgres + redis + localstack)"
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
  # -Dspring-boot.run.fork=false: by default the `run` goal FORKS a second JVM for the actual
  # Spring Boot app — `mvn` itself just supervises it. Killing that supervisor PID (which is
  # all `$!` below gives us) does not reliably kill the forked child; found this the hard way
  # while testing the LocalStack-outage checkpoint by hand: a killed script left 5 orphaned
  # app JVMs running and bound to the same ports, which then silently answered health checks
  # and API calls on the NEXT run against a stale/torn-down database connection. Running
  # unforked means there's exactly one JVM per service, and killing its PID is enough.
  (cd "$ROOT_DIR/apps/backend/$dir" && mvn -q spring-boot:run -Dspring-boot.run.fork=false \
      > "$LOG_DIR/$name.log" 2>&1 &
   echo $! > "$LOG_DIR/$name.pid")
  PIDS+=("$(cat "$LOG_DIR/$name.pid")")
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
# Unique email per run: customer-service enforces UNIQUE(email), and --keep-stack intentionally
# reuses the postgres volume across runs — a hardcoded email would 409 on the second run.
RUN_ID="$(date +%s)-$$"
log "Creating a customer…"
CUSTOMER_JSON=$(curl -fsS -X POST "$GATEWAY_URL/api/tmf-api/customerManagement/v4/customer" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"E2E Local Test\",\"email\":\"e2e-local-$RUN_ID@example.com\"}")
CUSTOMER_ID=$(echo "$CUSTOMER_JSON" | jq -r '.id')
[ -n "$CUSTOMER_ID" ] && [ "$CUSTOMER_ID" != "null" ] || fail "customer creation didn't return an id: $CUSTOMER_JSON"
ok "customer created: $CUSTOMER_ID"

log "Listing product offerings (Flyway seed data)…"
OFFERINGS_JSON=$(curl -fsS "$GATEWAY_URL/api/tmf-api/productCatalog/v4/productOffering?limit=10")
OFFERING_ID=$(echo "$OFFERINGS_JSON" | jq -r '.[0].id')
OFFERING_PRICE=$(echo "$OFFERINGS_JSON" | jq -r '.[0].priceAmount')
[ -n "$OFFERING_ID" ] && [ "$OFFERING_ID" != "null" ] || fail "no product offerings found — did Flyway seed data run?"
ok "found offering $OFFERING_ID (price=$OFFERING_PRICE)"

log "Placing an order (price is NOT sent by the client — see B-13)…"
ORDER_JSON=$(curl -fsS -X POST "$GATEWAY_URL/api/tmf-api/orderManagement/v4/productOrder" \
  -H 'Content-Type: application/json' \
  -d "{\"customerId\":\"$CUSTOMER_ID\",\"category\":\"new\",\"description\":\"e2e-local\",\"items\":[{\"productOfferingId\":\"$OFFERING_ID\",\"quantity\":1}]}")
ORDER_ID=$(echo "$ORDER_JSON" | jq -r '.id')
ORDER_TOTAL=$(echo "$ORDER_JSON" | jq -r '.totalAmount')
[ -n "$ORDER_ID" ] && [ "$ORDER_ID" != "null" ] || fail "order creation failed: $ORDER_JSON"
[ "$ORDER_TOTAL" = "$OFFERING_PRICE" ] || fail "order total ($ORDER_TOTAL) != catalog price ($OFFERING_PRICE) — price should come from product-catalog"
ok "order created: $ORDER_ID (total=$ORDER_TOTAL, matches catalog price)"

log "Polling for the invoice (outbox drainer → EventBridge → SQS → billing-service, every few seconds)…"
INVOICE_JSON=""
for _ in $(seq 1 30); do
  RESP=$(curl -fsS "$GATEWAY_URL/api/tmf-api/billingManagement/v4/customerBill?customerId=$CUSTOMER_ID&limit=10")
  if [ "$(echo "$RESP" | jq 'length')" -gt 0 ]; then
    INVOICE_JSON="$RESP"
    break
  fi
  sleep 3
done
[ -n "$INVOICE_JSON" ] || fail "no invoice appeared within 90s — check billing-service.log and order-management.log for the outbox/SQS chain"

INVOICE_AMOUNT=$(echo "$INVOICE_JSON" | jq -r '.[0].amount')
INVOICE_TAX=$(echo "$INVOICE_JSON" | jq -r '.[0].taxAmount')
EXPECTED_TAX=$(awk -v p="$OFFERING_PRICE" 'BEGIN { printf "%.2f", p * 0.10 }')
EXPECTED_TOTAL=$(awk -v p="$OFFERING_PRICE" -v t="$EXPECTED_TAX" 'BEGIN { printf "%.2f", p + t }')
[ "$(awk -v a="$INVOICE_TAX" -v b="$EXPECTED_TAX" 'BEGIN{print (a==b)}')" = "1" ] \
  || fail "invoice VAT ($INVOICE_TAX) != expected 10% of $OFFERING_PRICE ($EXPECTED_TAX)"
ok "invoice found with correct VAT: amount=$INVOICE_AMOUNT tax=$INVOICE_TAX (expected total ≈ $EXPECTED_TOTAL)"

echo ""
ok "ALL CHECKS PASSED — customer → plans → order → invoice works end-to-end through the gateway."

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

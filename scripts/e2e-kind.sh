#!/usr/bin/env bash
# End-to-end smoke test for the *kind* stack — same business flow as scripts/e2e-local.sh
# (customer → plans → order → invoice) but through the real Ingress at http://bss.localtest.me
# instead of `mvn spring-boot:run` on bare metal. This is the Giai đoạn 2 equivalent checkpoint
# of Giai đoạn 1's e2e-local.sh — see learning/20 Giai đoạn 2 checkpoint.
#
# Same B-52 discipline as e2e-local.sh: `set -euo pipefail`, every check is `curl -f` or an
# explicit `fail "..."` — nothing swallowed with `|| true` / `|| echo`.
#
# Prerequisites (see infrastructure/kubernetes/overlays/local/README.md):
#   ./scripts/kind-up.sh                          # cluster + ingress-nginx + metrics-server
#   docker build -t bss/<svc>:local ...            # x7, then `kind load docker-image` x7
#   kubectl --context kind-bss apply -k infrastructure/kubernetes/overlays/local
#
# Usage: ./scripts/e2e-kind.sh
set -euo pipefail

KCTX="kind-bss"
GATEWAY_URL="http://bss.localtest.me/api"

log()  { echo "→ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

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
curl -fsS -o /dev/null "http://bss.localtest.me/" || fail "GET / through the Ingress failed — is ingress-nginx installed? (scripts/kind-up.sh)"
ok "Ingress responds"

# ── 2. The actual business flow, through the Ingress, exactly like a browser would ─────────────
RUN_ID="$(date +%s)-$$"
log "Creating a customer…"
CUSTOMER_JSON=$(curl -fsS -X POST "$GATEWAY_URL/tmf-api/customerManagement/v4/customer" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"E2E Kind Test\",\"email\":\"e2e-kind-$RUN_ID@example.com\"}")
CUSTOMER_ID=$(echo "$CUSTOMER_JSON" | jq -r '.id')
[ -n "$CUSTOMER_ID" ] && [ "$CUSTOMER_ID" != "null" ] || fail "customer creation didn't return an id: $CUSTOMER_JSON"
ok "customer created: $CUSTOMER_ID"

log "Listing product offerings (Flyway seed data)…"
OFFERINGS_JSON=$(curl -fsS "$GATEWAY_URL/tmf-api/productCatalog/v4/productOffering?limit=10")
OFFERING_ID=$(echo "$OFFERINGS_JSON" | jq -r '.[0].id')
OFFERING_PRICE=$(echo "$OFFERINGS_JSON" | jq -r '.[0].priceAmount')
[ -n "$OFFERING_ID" ] && [ "$OFFERING_ID" != "null" ] || fail "no product offerings found — did Flyway seed data run?"
ok "found offering $OFFERING_ID (price=$OFFERING_PRICE)"

log "Placing an order (price is NOT sent by the client — see B-13)…"
ORDER_JSON=$(curl -fsS -X POST "$GATEWAY_URL/tmf-api/orderManagement/v4/productOrder" \
  -H 'Content-Type: application/json' \
  -d "{\"customerId\":\"$CUSTOMER_ID\",\"category\":\"new\",\"description\":\"e2e-kind\",\"items\":[{\"productOfferingId\":\"$OFFERING_ID\",\"quantity\":1}]}")
ORDER_ID=$(echo "$ORDER_JSON" | jq -r '.id')
ORDER_TOTAL=$(echo "$ORDER_JSON" | jq -r '.totalAmount')
[ -n "$ORDER_ID" ] && [ "$ORDER_ID" != "null" ] || fail "order creation failed: $ORDER_JSON"
[ "$ORDER_TOTAL" = "$OFFERING_PRICE" ] || fail "order total ($ORDER_TOTAL) != catalog price ($OFFERING_PRICE)"
ok "order created: $ORDER_ID (total=$ORDER_TOTAL, matches catalog price)"

log "Polling for the invoice (outbox drainer → EventBridge(LocalStack) → SQS → billing-service)…"
INVOICE_JSON=""
for _ in $(seq 1 30); do
  RESP=$(curl -fsS "$GATEWAY_URL/tmf-api/billingManagement/v4/customerBill?customerId=$CUSTOMER_ID&limit=10")
  if [ "$(echo "$RESP" | jq 'length')" -gt 0 ]; then
    INVOICE_JSON="$RESP"
    break
  fi
  sleep 3
done
[ -n "$INVOICE_JSON" ] || fail "no invoice appeared within 90s — check 'kubectl -n bss logs deploy/billing-service' and 'deploy/order-management'"

INVOICE_TAX=$(echo "$INVOICE_JSON" | jq -r '.[0].taxAmount')
EXPECTED_TAX=$(awk -v p="$OFFERING_PRICE" 'BEGIN { printf "%.2f", p * 0.10 }')
[ "$(awk -v a="$INVOICE_TAX" -v b="$EXPECTED_TAX" 'BEGIN{print (a==b)}')" = "1" ] \
  || fail "invoice VAT ($INVOICE_TAX) != expected 10% of $OFFERING_PRICE ($EXPECTED_TAX)"
ok "invoice found with correct VAT: tax=$INVOICE_TAX (expected $EXPECTED_TAX)"

echo ""
ok "ALL CHECKS PASSED — customer → plans → order → invoice works end-to-end through kind + ingress-nginx."

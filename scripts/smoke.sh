#!/usr/bin/env bash
# Quick smoke test against an environment's ALB.
# Usage:
#   ./scripts/smoke.sh dev
#
# Giai đoạn 5 / B-52: the old version had two bugs that together meant this script could NEVER
# fail, no matter what was actually broken:
#   1. `curl -fsSL ... | jq . || echo "  failed"` — `curl`'s own exit code (`-f` makes it fail on
#      HTTP >=400) was swallowed by the pipe to `jq`; even if it hadn't been, `|| echo "failed"`
#      turns a real failure into a SUCCESSFUL `echo` call, so `set -e` never triggers and the
#      script always exits 0. A rollback wired to "smoke test failed" (Giai đoạn 6, B-50/B-51)
#      would never fire.
#   2. `/api/actuator/health` was never a real route — api-gateway only ever exposed
#      `/api/tmf-api/**` (see B-03, apps/backend/api-gateway/src/main/resources/application.yml)
#      — so even a perfectly healthy stack would 404 on that path forever.
set -euo pipefail

ENV="${1:-dev}"
CLUSTER="bss-$ENV-eks"
REGION="${AWS_REGION:-ap-southeast-1}"

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

HOST=$(kubectl -n bss get ingress bss-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -z "$HOST" ]; then
  echo "✗ No ingress hostname yet — ALB may still be provisioning."
  exit 1
fi

echo "→ Smoke testing http://$HOST"

fail=0

check() {
  local label="$1" path="$2"
  echo ""
  echo "→ $label"
  if curl -fsSL --max-time 10 "http://$HOST$path" | jq . ; then
    echo "  ✓ ok"
  else
    echo "  ✗ FAILED"
    fail=1
  fi
}

# Real business endpoints through the gateway (not /api/actuator/health — see comment above).
# product-catalog's productOffering list is seeded at startup (see B-20/PR history), so it should
# always return >=1 item on a healthy stack, no test data required.
check "/api/tmf-api/productCatalog/v4/productOffering" "/api/tmf-api/productCatalog/v4/productOffering"
check "/api/tmf-api/customerManagement/v4/customer"    "/api/tmf-api/customerManagement/v4/customer"

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "✗ Smoke test FAILED — at least one endpoint did not respond 2xx with valid JSON."
  exit 1
fi

echo ""
echo "✓ Smoke test passed."

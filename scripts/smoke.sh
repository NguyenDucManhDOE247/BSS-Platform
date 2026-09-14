#!/usr/bin/env bash
# Quick smoke test against an environment's ALB.
# Usage:
#   ./scripts/smoke.sh dev
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
echo ""

echo "→ /api/actuator/health"
curl -fsSL "http://$HOST/api/actuator/health" | jq . || echo "  failed"

echo ""
echo "→ /api/tmf-api/customerManagement/v4/customer"
curl -fsSL "http://$HOST/api/tmf-api/customerManagement/v4/customer" | jq . || echo "  failed"

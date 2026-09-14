#!/usr/bin/env bash
# Tear down an environment to stop the AWS billing meter.
# Usage:
#   ./scripts/teardown.sh dev
#   ./scripts/teardown.sh staging
#
# NEVER use this on prod without explicit confirmation in CI.
set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ] || [[ ! "$ENV" =~ ^(dev|staging|prod)$ ]]; then
  echo "Usage: $0 <dev|staging|prod>" >&2
  exit 1
fi

if [ "$ENV" = "prod" ]; then
  echo "⚠ You're about to destroy PROD. Type 'destroy-prod' to confirm:"
  read -r confirmation
  if [ "$confirmation" != "destroy-prod" ]; then
    echo "Aborted."
    exit 1
  fi
fi

cd "$(dirname "$0")/../infrastructure/terraform/environments/$ENV"

echo "→ Terraform destroy on $ENV..."
terraform destroy -auto-approve

echo ""
echo "✓ $ENV torn down."
echo "  Note: S3 tfstate bucket + DynamoDB lock table are PRESERVED — they're"
echo "  account-level (created by bootstrap-aws.sh)."

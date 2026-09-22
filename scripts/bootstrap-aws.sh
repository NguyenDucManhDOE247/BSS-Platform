#!/usr/bin/env bash
# Bootstrap one-time AWS resources required BEFORE Terraform can run:
#   1. S3 bucket for Terraform state (with versioning + encryption)
#   2. (Optional) budget alert at 50/80/100% + forecasted
#
# Run this once per AWS account, NOT per environment.
#
# Usage:
#   ./scripts/bootstrap-aws.sh
#
# Prereqs:
#   - AWS CLI configured (aws sts get-caller-identity should succeed)
#   - You're logged in with an account that has IAM + S3 perms
set -euo pipefail

REGION="${AWS_REGION:-ap-southeast-1}"
BUDGET_USD="${BUDGET_USD:-30}"

# B-38: "bss-platform-tfstate" is an S3 bucket name — S3 bucket names are GLOBAL across every
# AWS account on earth, not just yours. Something that generic has almost certainly been taken
# by someone else already, and `create-bucket` fails with a confusing "already exists" error
# that looks like a permissions problem. Suffixing with your own account ID makes it unique by
# construction — nobody else has your account ID.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="bss-tfstate-${ACCOUNT_ID}"

echo "→ AWS account: $ACCOUNT_ID"
echo "→ Region:      $REGION"
echo "→ State bucket: $BUCKET"
echo ""

# ── 1. S3 bucket for tfstate ──────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "✓ Bucket $BUCKET already exists"
else
  echo "→ Creating S3 bucket $BUCKET..."
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"

  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
      "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
    }'

  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  echo "✓ Bucket ready"
fi

# ── 2. Budget alert ────────────────────────────────────────────────────
# No DynamoDB lock table: Terraform 1.10+ (this repo pins 1.7 as a *minimum*, but the actual
# CLI you run locally is almost certainly newer — check `terraform version`) can lock state
# directly on the S3 backend itself via `use_lockfile = true` (an object lock, no extra AWS
# service to create/pay for/IAM-permission separately). See the `backend "s3"` blocks in each
# environments/*/main.tf.
echo "→ Setting up monthly budget alert at \$$BUDGET_USD..."

NOTIFICATION_EMAIL="${OWNER_EMAIL:-}"
if [ -z "$NOTIFICATION_EMAIL" ]; then
  echo "⚠ OWNER_EMAIL not set, skipping budget. Re-run with OWNER_EMAIL=you@x.com to enable."
else
  cat > /tmp/budget.json <<EOF
{
  "BudgetName": "bss-platform-monthly",
  "BudgetLimit": {"Amount": "$BUDGET_USD", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
EOF
  # 4 thresholds: 50/80/100% of what's ACTUALLY been spent this month, plus a FORECASTED 100%
  # warning that fires *before* you actually overspend (AWS Cost Explorer's forecast, based on
  # this month's spend trend so far) — the ACTUAL ones alone only ever tell you after the fact.
  cat > /tmp/notifications.json <<EOF
[
  {"Notification": {"ComparisonOperator": "GREATER_THAN", "NotificationType": "ACTUAL", "Threshold": 50},
   "Subscribers": [{"Address": "$NOTIFICATION_EMAIL", "SubscriptionType": "EMAIL"}]},
  {"Notification": {"ComparisonOperator": "GREATER_THAN", "NotificationType": "ACTUAL", "Threshold": 80},
   "Subscribers": [{"Address": "$NOTIFICATION_EMAIL", "SubscriptionType": "EMAIL"}]},
  {"Notification": {"ComparisonOperator": "GREATER_THAN", "NotificationType": "ACTUAL", "Threshold": 100},
   "Subscribers": [{"Address": "$NOTIFICATION_EMAIL", "SubscriptionType": "EMAIL"}]},
  {"Notification": {"ComparisonOperator": "GREATER_THAN", "NotificationType": "FORECASTED", "Threshold": 100},
   "Subscribers": [{"Address": "$NOTIFICATION_EMAIL", "SubscriptionType": "EMAIL"}]}
]
EOF
  aws budgets create-budget \
    --account-id "$ACCOUNT_ID" \
    --budget file:///tmp/budget.json \
    --notifications-with-subscribers file:///tmp/notifications.json \
    2>/dev/null || echo "  (budget already exists)"
  echo "✓ Budget alert at 50%/80%/100% (actual) + 100% (forecasted) of \$$BUDGET_USD"
fi

echo ""
echo "──────────────────────────────────────────────────────────────"
echo "Bootstrap complete. Next step (repeat per environment: shared, dev, staging, prod):"
echo "  1. cd infrastructure/terraform/environments/<env>"
echo "  2. cp terraform.tfvars.example terraform.tfvars && edit it"
echo "  3. terraform init -backend-config=\"bucket=$BUCKET\""
echo "     (or just: make ENV=<env> tf-init — it fills this in for you)"
echo "  4. terraform apply"
echo "──────────────────────────────────────────────────────────────"

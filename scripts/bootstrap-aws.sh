#!/usr/bin/env bash
# Bootstrap one-time AWS resources required BEFORE Terraform can run:
#   1. S3 bucket for Terraform state (with versioning + encryption)
#   2. DynamoDB table for state locking
#   3. (Optional) IAM budget alert
#
# Run this once per AWS account, NOT per environment.
#
# Usage:
#   ./scripts/bootstrap-aws.sh
#
# Prereqs:
#   - AWS CLI configured (aws sts get-caller-identity should succeed)
#   - You're logged in with an account that has IAM + S3 + DynamoDB perms
set -euo pipefail

REGION="${AWS_REGION:-ap-southeast-1}"
BUCKET="bss-platform-tfstate"
TABLE="bss-platform-tflocks"
BUDGET_USD="${BUDGET_USD:-30}"

echo "→ AWS account: $(aws sts get-caller-identity --query Account --output text)"
echo "→ Region:      $REGION"
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

# ── 2. DynamoDB table for state locking ───────────────────────────────
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  echo "✓ DynamoDB table $TABLE already exists"
else
  echo "→ Creating DynamoDB table $TABLE..."
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"

  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
  echo "✓ Table ready"
fi

# ── 3. Budget alert ───────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
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
  cat > /tmp/notifications.json <<EOF
[{
  "Notification": {
    "ComparisonOperator": "GREATER_THAN",
    "NotificationType": "ACTUAL",
    "Threshold": 80
  },
  "Subscribers": [{"Address": "$NOTIFICATION_EMAIL", "SubscriptionType": "EMAIL"}]
}]
EOF
  aws budgets create-budget \
    --account-id "$ACCOUNT_ID" \
    --budget file:///tmp/budget.json \
    --notifications-with-subscribers file:///tmp/notifications.json \
    2>/dev/null || echo "  (budget already exists)"
  echo "✓ Budget alert at 80% of \$$BUDGET_USD"
fi

echo ""
echo "──────────────────────────────────────────────────────────────"
echo "Bootstrap complete. Next step:"
echo "  1. Edit infrastructure/terraform/environments/dev/main.tf"
echo "     and UNCOMMENT the backend \"s3\" { ... } block."
echo "  2. cd infrastructure/terraform/environments/dev"
echo "  3. cp terraform.tfvars.example terraform.tfvars && edit it"
echo "  4. terraform init && terraform apply"
echo "──────────────────────────────────────────────────────────────"

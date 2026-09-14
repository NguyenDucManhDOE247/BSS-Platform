#!/bin/bash
# Bootstraps LocalStack with the AWS resources our services expect.
# LocalStack runs this once when ready.
set -e

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=ap-southeast-1
ENDPOINT="--endpoint-url=http://localhost:4566"

echo "→ Creating EventBridge custom bus..."
awslocal events create-event-bus --name bss-dev-events

echo "→ Creating SQS queues..."
awslocal sqs create-queue --queue-name bss-dev-billing-orders-dlq
DLQ_ARN=$(awslocal sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/bss-dev-billing-orders-dlq \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

awslocal sqs create-queue --queue-name bss-dev-billing-orders \
  --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"5\\\"}\"}"

echo "→ Creating EventBridge rule + SQS target..."
QUEUE_ARN=$(awslocal sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/bss-dev-billing-orders \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

awslocal events put-rule \
  --name bss-dev-billing-orders \
  --event-bus-name bss-dev-events \
  --event-pattern '{"source":["bss.order"],"detail-type":["OrderCompleted","OrderRefunded"]}'

awslocal events put-targets \
  --rule bss-dev-billing-orders \
  --event-bus-name bss-dev-events \
  --targets "Id=1,Arn=$QUEUE_ARN"

echo "→ Creating Secrets Manager secrets..."
awslocal secretsmanager create-secret \
  --name bss-dev/rds/master \
  --secret-string '{"username":"bss","password":"bss","host":"postgres","port":5432}'

echo "✓ LocalStack bootstrap complete."

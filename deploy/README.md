# Local development stack

Brings up Postgres, Redis, and a LocalStack instance (fake AWS) so backend
services can run on your laptop with exactly the same env vars they'd see on EKS.

## Quick start

```bash
# 1. Start dependencies
docker compose up -d

# 2. Wait for LocalStack to bootstrap (creates EventBridge bus, SQS queues, secrets)
docker compose logs -f localstack | grep "LocalStack bootstrap complete"

# 3. Load env vars and run a service
set -a && source .env.example && set +a
cd ../apps/backend/customer-service
mvn spring-boot:run

# 4. Hit it
curl http://localhost:8080/actuator/health
```

## What you get

| Service     | Port | URL                                    |
|-------------|------|----------------------------------------|
| Postgres    | 5432 | `localhost:5432` (user/pass: bss/bss)  |
| Redis       | 6379 | `localhost:6379`                       |
| LocalStack  | 4566 | `http://localhost:4566`                |
| Adminer     | 8081 | `http://localhost:8081`                |

## Talking to LocalStack

```bash
# Install awslocal if you don't have it (or use plain aws + --endpoint-url)
pip install awscli-local

# List EventBridge buses
awslocal events list-event-buses

# Publish a test event
awslocal events put-events --entries '[{
  "Source": "bss.order",
  "DetailType": "OrderCompleted",
  "Detail": "{\"orderId\":\"abc\",\"customerId\":\"c1\",\"amount\":\"100000\"}",
  "EventBusName": "bss-dev-events"
}]'

# Check the billing queue
awslocal sqs receive-message --queue-url http://localhost:4566/000000000000/bss-dev-billing-orders
```

## Reset

```bash
docker compose down -v   # nuke all data
docker compose up -d     # fresh start, bootstrap runs again
```

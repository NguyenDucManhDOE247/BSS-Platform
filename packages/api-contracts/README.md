# @bss/api-contracts

OpenAPI specifications for every BSS public API. These are the source of truth
for both server (Spring Boot) and clients (frontend TypeScript, Postman, etc.).

## Layout

```
api-contracts/
├── customer-service.yaml   # TMF629 Customer Management
├── product-catalog.yaml    # TMF620 Product Catalog Management
├── order-management.yaml   # TMF622 Product Ordering Management
├── billing-service.yaml    # TMF678 Customer Bill Management
└── events/
    ├── OrderCompleted.schema.json   # JSON Schema for event payloads
    └── PaymentReceived.schema.json
```

## Generating clients

```bash
# TypeScript client for the web-portal:
npx openapi-typescript-codegen --input customer-service.yaml \
    --output ../../apps/frontend/web-portal/src/generated/customer

# Java client (for inter-service calls):
mvn org.openapitools:openapi-generator-maven-plugin:generate \
    -Dinput=customer-service.yaml -Dlang=java
```

> Keep specs **backward-compatible**: add fields only, never remove. Use
> `deprecated: true` and remove only after one full release cycle.

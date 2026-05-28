# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Nothing yet.

## [0.1.0] — 2026-05-28

First public release — **Phase 1 (local development) is code-complete**.
The platform builds and runs end-to-end against Postgres + LocalStack via
`docker-compose`. AWS-side work (Phase 2+) is scaffolded but not yet executed.

### Added

- **Backend services** (Java 21, Spring Boot 3.2):
  - `customer-service` — TMF629 CRUD + PATCH (`application/merge-patch+json`).
  - `product-catalog` — TMF620 with `Category`, `ProductSpecification`,
    `ProductOffering`, seeded with 4 sample plans.
  - `order-management` — TMF622 with a **transactional outbox** pattern
    publishing `OrderCompleted` events to EventBridge.
  - `billing-service` — TMF678 with `BillingAccount`, `Invoice`, VAT 10 %,
    and an **idempotent SQS consumer** using a `processed_event` dedup table.
  - `api-gateway` — Spring Cloud Gateway with routing for the four services.
- **Frontend apps** (Vite + React 18 + TypeScript):
  - `web-portal` — Home / Plans / Order / Bills pages calling real APIs.
  - `admin-console` — Dashboard, Customers, Offerings management.
- **Shared packages**: `bss-common-java`, `ui-kit`, `api-contracts`
  (OpenAPI 3.1 specs for all four TMF APIs).
- **Infrastructure**:
  - Terraform modules: `vpc`, `eks`, `rds`, `ecr`, `eventbridge`, `iam`,
    `observability`.
  - Three environments: `dev` / `staging` / `prod`.
  - Kustomize base + overlays for all seven services.
  - Helm values for in-cluster addons (Prometheus, Fluent Bit, OTel,
    Karpenter, ALB Controller, ExternalDNS, Secrets Store CSI).
- **CI/CD** — seven GitHub Actions workflows with OIDC auth, path filters,
  and tag-based promotion (`rc-v*` → staging, `v*` → prod with manual approval).
- **Local dev** — `docker-compose` stack: Postgres + Redis + LocalStack
  with init scripts for databases, EventBridge bus, and SQS queues.
- **Scripts**: `bootstrap-aws.sh`, `teardown.sh`, `smoke.sh`.
- **Docs**: `CLAUDE.md` (architecture + roadmap), `README.md`, `docs/SETUP.md`,
  `docs/ROADMAP.md`, ADR scaffolding.

### Security

- IRSA + GitHub OIDC throughout — no static AWS keys.
- Trivy scanning in CI on every backend / frontend build.
- Pod `securityContext`: `runAsNonRoot`, `readOnlyRootFilesystem`, all caps dropped.
- ECR repos with immutable tags.

[Unreleased]: https://github.com/gemmy94/bss-platform/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/gemmy94/bss-platform/releases/tag/v0.1.0

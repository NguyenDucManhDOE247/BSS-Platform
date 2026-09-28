# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — 2026-09-28

Everything below shipped after `v0.1.0` (local-only scaffold) and is verified against **real AWS
infrastructure**, not just written and assumed working — see `docs/adr/` for the decisions and
`docs/runbooks/` for the verification evidence. Phase 8 closed with measured capacity (stable to >=150 req/s on 2x t3.medium; beyond that pods go
`Pending` for lack of node capacity, see ADR-007) and chaos results recorded in `docs/labs/`.

### Added

- **Kubernetes local (`kind`) + observability local** — full stack on `kind` via Kustomize,
  kube-prometheus-stack, Alertmanager, `NetworkPolicy` (Calico-verified), k6 load test.
- **CI on GitHub Actions** — 4 workflows (backend/frontend/terraform/k8s) actually executing
  tests and gating on Trivy findings; SHA-pinned actions; Dependabot.
- **Real AWS infrastructure** — Terraform for VPC/EKS/RDS/ECR/EventBridge/IAM across
  `dev`/`staging`/`prod`/`shared`, IRSA per service, GitHub OIDC deployer roles (no static AWS keys).
- **CD pipeline** — merge-to-`main` auto-deploys dev; `rc-vX` tag promotes to staging; `vX` tag +
  manual approval promotes to prod; automatic rollback to the last-known-good release manifest on
  a failed smoke test.
- **Observability on AWS** — Prometheus/Grafana/Alertmanager, Fluent Bit → CloudWatch (JSON logs +
  `trace_id`), OTel → X-Ray, an SLO with a multi-window burn-rate alert for `order-management`.
- **Security hardening** — NetworkPolicy default-deny + whitelist, Keycloak + OAuth2 Resource
  Server on the gateway, AWS WAF in front of the ALB (managed rule groups + rate limiting),
  Pod Security `restricted`, Trivy config scanning.
- **Reliability tooling (Phase 8)** — `tests/load/dev-threshold.js` (k6 capacity-threshold test
  against real dev EKS), `scripts/chaos-delete-pod.sh` / `scripts/chaos-drain-node.sh` chaos
  experiments, `tools/ops/` day-2 scripts (`cost_report.py`, `dlq_tool.py`, `health_check.py`).
- **Documentation** — 7 ADRs, 10+ runbooks, `docs/POSTMORTEMS.md`, a public `docs/ROADMAP.md`.

### Fixed

- Dozens of real bugs found by actually running each phase's checkpoint against live
  infrastructure rather than trusting green CI or "looks correct" code review — see
  `docs/POSTMORTEMS.md` for the most instructive one (a dedup mechanism that looked fixed but was
  a silent no-op for ~4 months because of a JPA `merge()`-vs-`persist()` mismatch).

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

[Unreleased]: https://github.com/NguyenDucManhDOE247/BSS-Platform/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/NguyenDucManhDOE247/BSS-Platform/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/NguyenDucManhDOE247/BSS-Platform/releases/tag/v0.1.0

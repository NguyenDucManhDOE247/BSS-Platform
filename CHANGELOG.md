# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Debt pass from Phase 8 back to 0 (after `v2.0.0`), each item verified on real infrastructure.

### Added

- **Keycloak production-grade** — [ADR-011](docs/adr/ADR-011-keycloak-production-grade.md): own image
  `apps/identity/keycloak` (`kc.sh build` → `start --optimized`, startup ~5 s), `readOnlyRootFilesystem: true`
  (last exception in the repo removed), **2 replicas on prod** clustered via `jdbc-ping` with DB-persisted
  sessions, PDB `maxUnavailable: 1`, JGroups-only NetworkPolicy rule. Managed by CD as the 8th image
  (`release-manifest.sh`; new `previous` command handles pre-ADR-011 7-service manifests). New
  `ci-keycloak.yml` (build + Trivy + real 2-replica run).
- **Karpenter 1.14.1 on dev** (Spot first) — [ADR-010](docs/adr/ADR-010-karpenter-lam-that-o-dev.md)
  supersedes ADR-007; IAM translated from the official template; node `Ready` ~36 s; 200→700 req/s served
  2.4× more requests than fixed nodes (p95 3.66 s vs 8.55 s, but 7.9% errors — see ADR-010).
- **NetworkPolicy enforcement on EKS** (VPC CNI `enableNetworkPolicy`, dev) + `scripts/netpol-matrix.sh`
  run from inside real service pods (11/11 on EKS, 10/10 on kind).
- **IRSA for Fluent Bit and the OTel Collector** — logs reach CloudWatch as JSON with `trace_id`, traces
  reach X-Ray (a log's `trace_id` resolves to a 13-segment trace across EventBridge → SQS).
- `tools/ops/orphan_finder.py` — lists anything still billing after `terraform destroy`.
- Schema migration Release B/C for `customers.email_verified` (expand → migrate → contract), run on RDS.
- Real Discord alert delivery (alert + runbook link in 132–146 s after a service goes down).
- ADR-009 (no Jenkins/Helm chart/Ansible alongside the current toolchain).
- **`Idempotency-Key` on `POST productOrder`** (B-15): a double-click or an automatic retry no longer
  creates a second order + invoice — the same (user, key) returns the original order (`201` +
  `Idempotent-Replayed: true`); same key with a different body → 422; a concurrent duplicate loses on the
  `(owner_sub, idem_key)` primary key, rolls back its whole order and gets 409. web-portal sends one key per
  order page (with a `getRandomValues` fallback, since `crypto.randomUUID` needs a secure context).

### Changed

- **`bss-common-java` 0.2.0 is used by all 4 business services** (B-15): one RFC 7807 handler,
  `NotFoundException`, `OffsetPageRequest` (4 identical copies removed; `previousOrFirst()` no longer goes
  negative) and `CurrentCaller` (3 copies removed; a missing JWT is now 401 everywhere instead of 500 in
  order/billing). The library imports the Spring Boot 3.5.16 BOM instead of pinning Spring by hand.
- **Primary keys are UUID v7** (RFC 9562) via `UuidV7Generator` — time-ordered, so new rows append to the end
  of the B-tree index. No migration needed; existing v4 ids stay valid.
- **PATCH is real JSON Merge Patch (RFC 7396)** in customer-service and product-catalog: an omitted field is
  kept, `null` clears it (`phoneNumber`, `description`, `validForStart/End`), `null` on a required field is
  422. Before, `null` meant "keep", so a customer could not remove their phone number. DTOs use
  `JsonNullable<T>` — `Optional<T>` in a record cannot tell "absent" from `null` (verified).

- **Auth is always on — the `bss.auth.enabled` switch is gone** (ADR-008 decision 6): no more "open" filter
  chains, `BSS_AUTH_ENABLED` env vars or auth-off branches in the 5 services; a service without an issuer/JWKS
  now fails to start instead of running unauthenticated. `scripts/e2e-local.sh` (docker-compose + `mvn`) now
  signs up a real Keycloak user, gets approved, orders and checks ownership (404) like `e2e-kind.sh`.
  `CreateOrderRequest.customerId` removed (the customer is whoever the token says).
- **Keycloak 26.5 → 26.7.4** everywhere (kind, docker-compose, AWS): 26.5.7 carried Keycloak CVEs incl.
  CVE-2026-18963 (CRITICAL, unauthenticated account takeover). 6 remaining CVEs in libraries bundled by
  Keycloak are listed with reasons in `apps/identity/keycloak/.trivyignore`.
- **Spring Boot 3.2.12 → 3.5.16** (+ patch overrides for Tomcat/Jackson/pgjdbc/Netty): Trivy HIGH/CRITICAL
  34 → **0** per image; all temporary `.trivyignore` entries removed. The old "Flyway breaks on 3.5" was a
  missing `flyway-database-postgresql` module.
- Dev node group 3 → 2 (Karpenter adds capacity on demand).

### Fixed

- Found by running the Definition-of-Done checks **from a clean clone** (existing environments hid all of them):
  `kind-up.sh` failed on a brand-new cluster (`kubectl wait` before the ingress pod existed); 4 scripts committed without
  the executable bit (B-07 again — `ci-scripts` now rejects any non-100755 `*.sh`); `e2e-local.sh` left Maven + app JVMs
  orphaned on ports 8080–8084 (it killed only the `mvn` wrapper — services now run in their own process group) and
  now refuses to start when those ports are taken.
- `teardown.sh` got stuck on `DeleteSubnet: DependencyViolation`: a Karpenter Spot node's secondary ENI was never
  reclaimed by the VPC CNI and kept the EKS cluster security group alive. teardown now removes those (by cluster tag)
  and retries once; `orphan_finder.py` reports leftover EKS security groups and no longer crashes on a cp1252 console.
- The 4 OpenAPI contracts in `packages/api-contracts/` were not valid YAML (a backtick cannot start a token
  inside a `{ description: … }` flow mapping) — every OpenAPI tool would reject them.
- Rolling updates dropped requests (1/419 → 500): `preStop` sleep 10 s on every Deployment.
- `teardown.sh`: waits for / removes leftover ALB target groups, PVC-backed EBS volumes and Karpenter
  nodes before `terraform destroy`; runs `orphan_finder` at the end.
- Karpenter silently fell back to On-Demand on a fresh account (missing `AWSServiceRoleForEC2Spot`) —
  now created by `bootstrap-aws.sh`.
- Flaky CI (kustomize install hit the unauthenticated GitHub API rate limit).

## [2.0.0] — 2026-09-29

Giai đoạn 9 — "sản phẩm hoàn chỉnh": danh tính thật + quyền sở hữu dữ liệu + 2 website có đăng nhập
([ADR-008](docs/adr/ADR-008-danh-tinh-va-quyen-so-huu.md)). Shipped `rc-v2.0.0` → staging →
`v2.0.0` → prod (manual approval) on the same commit `b75b43f`, each environment smoke-tested for
real and destroyed afterwards (ADR-006).

### ⚠️ Breaking

- **Every non-public API now requires a Keycloak JWT** on dev/staging/prod and kind (only browsing
  product offerings stays public). Before 2.0.0 the AWS environments accepted anonymous calls (B-18).
- `POST /productOrder` ignores `customerId` from the body — the customer is the caller's own
  profile (`GET /customer/me`), and only `Active` (admin-approved) customers may order (422 otherwise).
- Customers only see their own orders/invoices/billing accounts; reading someone else's returns 404.

### Added

- **Identity** — Keycloak realm shared by every environment (`components/keycloak-realm`, no test
  users outside local); self-registration + `/customer/me`; admin approves `Initialized → Active`.
- **web-portal** — register/login (Authorization Code + PKCE), profile, "my orders", "my invoices".
- **admin-console** — admin-only; customers (search, paging, edit, approve/lock), offerings (create,
  reprice, retire), system-wide orders + invoices filtered by customer, dashboard with real totals
  (`X-Total-Count`) and revenue (`GET /customerBill/summary`, summed in the database).
- **Keycloak on EKS** (`components/keycloak-aws`) — production mode, own Postgres DB on RDS,
  secrets via Secrets Manager + CSI, IRSA; not exposed on the ALB until HTTPS exists (ADR-008
  decision 8). Dev node group 2 → 3.
- **Tests** — Playwright browser E2E on kind (`scripts/e2e-browser.sh`), `e2e-kind.sh` rewritten for
  auth (fresh Keycloak user per run, ownership + "old orders keep their price" checks), `smoke.sh`
  checks both directions of auth (401 without token, 403 for the wrong role).

### Known limitations

- No HTTPS on AWS yet → browser login works on kind only; on AWS the websites serve anonymous
  browsing and the API is secured (tracked as a deferred item in the roadmap).
- Keycloak runs 1 replica and `start` without `--optimized` (writable root filesystem).

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

# BSS Platform on AWS EKS

> Production-grade reference implementation of a **Business Support System (BSS)** running on **Amazon EKS** — full monorepo with frontend, backend microservices, Infrastructure-as-Code, GitHub Actions CI/CD, and an observability stack.

[![CI Backend](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-backend.yml/badge.svg)](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-backend.yml)
[![CI Frontend](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-frontend.yml/badge.svg)](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-frontend.yml)
[![CI Terraform](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-terraform.yml/badge.svg)](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-terraform.yml)
[![CI Kubernetes](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-k8s.yml/badge.svg)](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-k8s.yml)
[![Java](https://img.shields.io/badge/Java-21-007396?logo=openjdk)](https://openjdk.org/projects/jdk/21/)
[![Spring Boot](https://img.shields.io/badge/Spring%20Boot-3.5-6DB33F?logo=spring-boot)](https://spring.io/projects/spring-boot)
[![Terraform](https://img.shields.io/badge/Terraform-1.16+-7B42BC?logo=terraform)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws)](https://aws.amazon.com/eks/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-v2.0.0%20%E2%80%94%20Phases%200--9%20done-brightgreen)](docs/ROADMAP.md)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

## Table of contents

- [What's here](#whats-here)
- [Architecture](#architecture)
- [Microservices (TM Forum-aligned)](#microservices-tm-forum-aligned)
- [Tech stack](#tech-stack)
- [Quick start](#quick-start)
- [Project status](#project-status)
- [Cost](#cost)
- [Learning roadmap](#learning-roadmap)
- [Repo conventions](#repo-conventions)
- [Contributing & security](#contributing--security)
- [License](#license)

## What's here

A complete monorepo: **2 websites + 5 backends + Keycloak + shared libs + 4-state infrastructure + CI/CD**.

```
bss-platform/
├── apps/
│   ├── frontend/       web-portal, admin-console        (Vite + React, OIDC/PKCE login)
│   ├── backend/        api-gateway + 4 services         (Spring Boot 3.5, Java 21, JWT resource servers)
│   └── identity/       keycloak                         (optimized image for AWS — ADR-011)
├── packages/           bss-common-java, ui-kit, api-contracts (OpenAPI 3.1)
├── infrastructure/
│   ├── terraform/      9 modules + environments/{shared,dev,staging,prod}
│   └── kubernetes/     base/ + components/ (keycloak) + overlays/{local,dev,staging,prod}
├── platform/           addon values + install scripts (ALB, Secrets CSI, Karpenter, Prometheus, Fluent Bit, OTel)
├── deploy/             docker-compose: Postgres, Redis, LocalStack, Keycloak
├── .github/workflows/  10 CI/CD pipelines (path-filter + tag-based promotion)
├── scripts/            e2e-local/kind/browser, release-manifest (CD), smoke, bootstrap, teardown, …
├── tools/ops/          Python ops tools (orphan finder, cost report, DLQ, health check)
└── tests/              k6 load tests + Playwright browser E2E
```

## Architecture

```
   Internet
      │ HTTP (HTTPS pending a domain — B-23)
      ▼
  AWS WAF → ALB
      │
      ▼
  ┌──────────────────────── EKS Cluster ────────────────────────┐
  │                                                              │
  │  Frontend pods       Backend pods            Platform        │
  │  ─────────────       ────────────            ────────        │
  │  web-portal          api-gateway             Prometheus      │
  │  admin-console       Keycloak (2 on prod)    Grafana         │
  │                      customer-service        Alertmanager    │
  │                      product-catalog         Fluent Bit      │
  │                      order-management ──┐    OTel Collector  │
  │                      billing-service  <─┤    Karpenter (dev) │
  │                                         │                    │
  └─────────────────────────────────────────┼────────────────────┘
                                            │
       ┌────────────────────────────────────┼────────────────┐
       ▼                                    ▼                ▼
  RDS PostgreSQL                   EventBridge → SQS    Secrets Manager
                                                        + X-Ray + CloudWatch
```

## Microservices (TM Forum-aligned)

| Service | Responsibility | TMF API |
|---|---|---|
| `customer-service` | Customer lifecycle, identity | TMF629 |
| `product-catalog`  | Plans, offers, pricing       | TMF620 |
| `order-management` | Order capture + orchestration | TMF622 |
| `billing-service`  | Charging, invoicing, payment | TMF678 |
| `api-gateway`      | Routing, coarse auth (401/403) | — |
| Keycloak           | Identity: self-registration, OIDC/PKCE, roles `customer`/`admin` | — |

## Tech stack

| Layer | Tech |
|---|---|
| Cloud | AWS (EKS, RDS, ECR, EventBridge, SQS, ALB, WAF, Secrets Manager, CloudWatch, X-Ray) |
| Backend | Java 21, Spring Boot 3.5, Spring Cloud Gateway, Spring Security (JWT), Resilience4j, AWS SDK v2 |
| Identity | Keycloak 26.7 (OIDC + PKCE), per-customer data ownership by `sub` ([ADR-008](docs/adr/ADR-008-danh-tinh-va-quyen-so-huu.md)) |
| Frontend | Vite, React 18, TypeScript, react-query |
| Container | Multi-stage Docker (distroless-style), non-root |
| Orchestration | EKS 1.34 + Managed Node Groups; Karpenter (Spot) on dev ([ADR-010](docs/adr/ADR-010-karpenter-lam-that-o-dev.md)) |
| IaC | Terraform ≥ 1.10 (S3 native state locking) + hashicorp/aws |
| K8s packaging | Kustomize (base + components + overlays/local|dev|staging|prod) |
| CI/CD | GitHub Actions + OIDC → IAM Role (no static keys) |
| Observability | kube-prometheus-stack (in-cluster) + Fluent Bit → CloudWatch + OTel → X-Ray |
| Secrets | AWS Secrets Manager + Secrets Store CSI Driver |

## Quick start

Full, verified walkthrough: **[docs/SETUP.md](docs/SETUP.md)** (tools → local → kind → AWS → teardown, each step
with a check). The short version:

```bash
./scripts/e2e-local.sh --stay-up          # docker-compose + 5 backends + Keycloak, full business flow, then keep running
cd apps/frontend/web-portal && npm ci && npm run dev    # http://localhost:3000

# Kubernetes on your laptop ($0) — see infrastructure/kubernetes/overlays/local/README.md
./scripts/kind-up.sh && ./scripts/auth-install.sh kind && make build-images   # then kind load + kubectl apply -k …/overlays/local
./scripts/e2e-kind.sh && ./scripts/e2e-browser.sh

# AWS (costs money — read every plan)
./scripts/bootstrap-aws.sh                                # once per account
make ENV=shared tf-init tf-apply                          # ECR, GitHub OIDC, deployer roles — once
make ENV=dev tf-init tf-plan tf-apply                     # ~20 min
./scripts/platform-install.sh dev                         # then db-bootstrap, then run "CD — dev" in GitHub Actions
make ENV=dev tf-destroy                                   # every evening

git tag rc-v2.1.0 <sha> && git push origin rc-v2.1.0      # → staging
git tag v2.1.0 <sha>    && git push origin v2.1.0         # → prod (manual approval)
```

## Project status

Phase-by-phase tracking lives in [docs/ROADMAP.md](docs/ROADMAP.md). Today:

| Phase | Status |
|---|---|
| 0 — Scaffold (monorepo, Terraform modules, CI/CD, docker-compose) | ✅ Done |
| 1 — Local dev end-to-end (5 backends, 2 frontends, real browser run) | ✅ Done |
| 2 — Kubernetes local (`kind`) + observability local | ✅ Done |
| 3 — CI green on GitHub (tests actually executing) | ✅ Done |
| 4 — Terraform + real AWS bootstrap (`apply`/`destroy`, no orphans) | ✅ Done |
| 5 — Deploy dev to real EKS (RDS, EventBridge/SQS, ALB) | ✅ Done |
| 6 — CD: dev auto-deploy → staging/prod tag-based promotion + rollback | ✅ Done |
| 7 — Observability + security on AWS (dashboards, OAuth2, WAF, Trivy gate) | ✅ Done |
| 8 — Reliability, load test, ops tooling, docs, `v1.0.0` | ✅ Done |
| 9 — Real product: Keycloak identity (PKCE), self-registration → admin approval, per-customer data ownership, `v2.0.0` on prod | ✅ Done |
| Debt pass 8 → 0 — Karpenter (Spot) on dev, NetworkPolicy enforced on EKS, Spring Boot 3.5 (0 HIGH/CRITICAL CVE), orphan finder | ✅ Done |
| Hardening after Phase 9 — production-grade Keycloak (2 replicas, read-only rootfs), auth always on, Definition of Done reviewed from a clean clone ([ROADMAP](docs/ROADMAP.md#definition-of-done-for-v100)) | ✅ Done — except HTTPS (B-23, needs a domain) |

Every ✅ above was verified against **real infrastructure**, not just written and assumed working —
see [`docs/adr/`](docs/adr/) for the decisions and [`docs/runbooks/`](docs/runbooks/) for the
verification evidence. See [CHANGELOG.md](CHANGELOG.md) for the release history.

### The two websites (Phase 9)

A customer registers on **web-portal**, waits for approval, buys a plan, and sees only their own
invoices; staff approve customers and manage plans, orders and invoices on **admin-console**. Screenshots
are from the Playwright browser test (`scripts/e2e-browser.sh`) on `kind` — test data only.

| web-portal (customer) | admin-console (staff) |
|---|---|
| ![Waiting for approval — cannot buy yet](docs/images/web-portal-cho-duyet.png) | ![Approving a self-registered customer](docs/images/admin-console-duyet-khach.png) |
| ![My invoices — only this customer's, VAT 10%](docs/images/web-portal-hoa-don-cua-toi.png) | ![Dashboard — real totals and revenue](docs/images/admin-console-dashboard.png) |
| | ![One customer's invoices, filtered by staff](docs/images/admin-console-hoa-don-cua-khach.png) |

> Browser login works on `kind` today. On AWS the API is secured (401/403 verified by the CD smoke
> test) but the websites can't sign users in until there is HTTPS — see
> [ADR-008](docs/adr/ADR-008-danh-tinh-va-quyen-so-huu.md) decision 8.

## Cost

Real, ADR-backed numbers (see [ADR-002](docs/adr/ADR-002-mang-dev.md) for the dev network cost
analysis) — not an initial estimate:

| Environment | Pattern | Approx. cost |
|---|---|---|
| Dev | `terraform apply` for a session, `destroy` right after (no idle spend) | ~$1.5–2/hour while the cluster is up |
| Staging / Prod | Ephemeral — stood up per demo/release, destroyed after (see [ADR-006](docs/adr/ADR-006-staging-prod-ephemeral.md)) | Same per-hour order of magnitude as dev, ×3 node count |

> No environment in this project runs 24/7. This is a deliberate cost control for a
> self-funded learning project, tracked with a monthly AWS Budget alert (CLAUDE.md §4).

## Learning roadmap

10 phases from "install tooling" to "publish blog post." See [docs/ROADMAP.md](docs/ROADMAP.md).

## Repo conventions

This repo is co-developed with Claude Code. The full set of architectural decisions, coding conventions, security rules, and Phase-by-phase plan lives in [CLAUDE.md](CLAUDE.md).

## Contributing & security

- [CONTRIBUTING.md](CONTRIBUTING.md) — dev environment, commit convention, code style, PR checklist.
- [SECURITY.md](SECURITY.md) — how to report a vulnerability (please **don't** open public issues for security bugs).
- [CHANGELOG.md](CHANGELOG.md) — Keep-a-Changelog history.

## License

MIT — see [LICENSE](LICENSE).

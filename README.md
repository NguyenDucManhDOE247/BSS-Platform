# BSS Platform on AWS EKS

> Production-grade reference implementation of a **Business Support System (BSS)** running on **Amazon EKS** — full monorepo with frontend, backend microservices, Infrastructure-as-Code, GitHub Actions CI/CD, and an observability stack.

[![CI Backend](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-backend.yml/badge.svg)](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-backend.yml)
[![CI Frontend](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-frontend.yml/badge.svg)](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-frontend.yml)
[![CI Terraform](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-terraform.yml/badge.svg)](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-terraform.yml)
[![CI Kubernetes](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-k8s.yml/badge.svg)](https://github.com/NguyenDucManhDOE247/BSS-Platform/actions/workflows/ci-k8s.yml)
[![Java](https://img.shields.io/badge/Java-21-007396?logo=openjdk)](https://openjdk.org/projects/jdk/21/)
[![Spring Boot](https://img.shields.io/badge/Spring%20Boot-3.2-6DB33F?logo=spring-boot)](https://spring.io/projects/spring-boot)
[![Terraform](https://img.shields.io/badge/Terraform-1.16+-7B42BC?logo=terraform)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws)](https://aws.amazon.com/eks/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Phase%207%20done%20%E2%80%94%20Phase%208%20in%20progress-blue)](docs/ROADMAP.md)
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

A complete monorepo: **2 frontends + 5 backends + shared libs + 3-env infrastructure + CI/CD**.

```
bss-platform/
├── apps/
│   ├── frontend/       web-portal, admin-console        (Vite + React)
│   └── backend/        api-gateway + 4 services         (Spring Boot 3, Java 21)
├── packages/           bss-common-java, ui-kit, api-contracts
├── infrastructure/
│   ├── terraform/      modules/ + environments/{dev,staging,prod}
│   └── kubernetes/     base/ + overlays/{dev,staging,prod}
├── platform/           helm values for cluster addons (ALB, ExternalDNS, Karpenter, ...)
├── deploy/             docker-compose + LocalStack for local dev
├── .github/workflows/  7 CI/CD pipelines (path-filter + tag-based promotion)
└── scripts/            bootstrap-aws, teardown, smoke
```

## Architecture

```
   Internet
      │ HTTPS
      ▼
  CloudFront → ALB → AWS WAF
      │
      ▼
  ┌──────────────────────── EKS Cluster ────────────────────────┐
  │                                                              │
  │  Frontend pods       Backend pods            Platform        │
  │  ─────────────       ────────────            ────────        │
  │  web-portal          api-gateway             Prometheus      │
  │  admin-console       customer-service        Grafana         │
  │                      product-catalog         Fluent Bit      │
  │                      order-management ──┐    OTel Collector  │
  │                      billing-service  <─┤    metrics-server  │
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
| `api-gateway`      | Routing, auth, rate limit    | — |

## Tech stack

| Layer | Tech |
|---|---|
| Cloud | AWS (EKS, RDS, ECR, EventBridge, SQS, S3, ALB, CloudFront, Route 53) |
| Backend | Java 21, Spring Boot 3.2, Spring Cloud Gateway, AWS SDK v2 |
| Frontend | Vite, React 18, TypeScript, react-query |
| Container | Multi-stage Docker (distroless-style), non-root |
| Orchestration | EKS 1.34 + Managed Node Groups (Karpenter evaluated, not adopted — see [ADR-007](docs/adr/ADR-007-karpenter.md)) |
| IaC | Terraform 1.7 + hashicorp/aws 5.x |
| K8s packaging | Kustomize (base + overlays/dev|staging|prod) |
| CI/CD | GitHub Actions + OIDC → IAM Role (no static keys) |
| Observability | kube-prometheus-stack (in-cluster) + Fluent Bit → CloudWatch + OTel → X-Ray |
| Secrets | AWS Secrets Manager + Secrets Store CSI Driver |

## Quick start

**Prerequisites:** `aws-cli`, `terraform 1.7+`, `kubectl`, `helm`, `kustomize`, `docker`, `jdk21`, `node 20`, `make`.

### 1. Local development (no AWS needed)

```bash
make local-up                                         # Postgres + Redis + LocalStack
cd apps/backend/customer-service && mvn spring-boot:run
# In another shell:
cd apps/frontend/web-portal && npm install && npm run dev
```

Open http://localhost:3000.

### 2. Deploy dev infrastructure on AWS

```bash
make bootstrap                                        # one-time: S3 tfstate + DynamoDB + budget
make ENV=dev tf-init && make ENV=dev tf-apply         # ~20 minutes for EKS
make ENV=dev kube-config                              # update local kubeconfig

# Install cluster addons (see platform/README.md for full sequence)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system ...
# ... etc.

# Push + deploy customer-service:
make ENV=dev SERVICE=customer-service push set-image deploy
make ENV=dev smoke
```

### 3. Promote to staging / prod

```bash
git tag rc-v0.1.0 && git push --tags                  # → cd-staging
git tag v0.1.0    && git push --tags                  # → cd-prod (manual approval)
```

Full step-by-step guide in [docs/SETUP.md](docs/SETUP.md).

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
| 8 — Reliability, load test, ops tooling, docs, `v1.0.0` demo | 🚧 In progress |

Every ✅ above was verified against **real infrastructure**, not just written and assumed working —
see [`docs/adr/`](docs/adr/) for the decisions and [`docs/runbooks/`](docs/runbooks/) for the
verification evidence. See [CHANGELOG.md](CHANGELOG.md) for the release history.

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

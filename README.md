# BSS Platform on AWS EKS

> Production-grade reference implementation of a **Business Support System (BSS)** running on **Amazon EKS** — full monorepo with frontend, backend microservices, Infrastructure-as-Code, GitHub Actions CI/CD, and an observability stack.

[![CI Backend](https://github.com/YOUR_USERNAME/bss-platform/actions/workflows/ci-backend.yml/badge.svg)](https://github.com/YOUR_USERNAME/bss-platform/actions/workflows/ci-backend.yml)
[![Terraform](https://img.shields.io/badge/Terraform-1.7+-7B42BC?logo=terraform)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.30+-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws)](https://aws.amazon.com/eks/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

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
  │                      billing-service  <─┤    Karpenter       │
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
| Orchestration | EKS 1.30 + Managed Node Groups + Karpenter |
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

## Cost

| Environment | USD/day |
|---|---|
| Dev (`tf-destroy` nightly) | ~$5 |
| Dev (always on) | ~$5 |
| Staging | ~$9 |
| Prod | ~$30+ |

> AWS Free Tier (first 12 months) reduces dev cost to ~$3/day for RDS + EC2.
> The EKS control plane ($0.10/hour) is **not** free-tier eligible.

## Learning roadmap

10 phases from "install tooling" to "publish blog post." See [docs/ROADMAP.md](docs/ROADMAP.md).

## Repo conventions

This repo is co-developed with Claude Code. The full set of architectural decisions, coding conventions, security rules, and Phase-by-phase plan lives in [CLAUDE.md](CLAUDE.md).

## License

MIT — see [LICENSE](LICENSE).

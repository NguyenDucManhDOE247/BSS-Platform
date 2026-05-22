# BSS Platform on GKE

> Production-grade reference implementation of a **Business Support System (BSS)** running on **Google Kubernetes Engine** — with Infrastructure-as-Code, automated CI/CD, and full observability stack.

[![CI](https://github.com/YOUR_USERNAME/bss-platform-gke/actions/workflows/ci.yml/badge.svg)](https://github.com/YOUR_USERNAME/bss-platform-gke/actions/workflows/ci.yml)
[![Terraform](https://img.shields.io/badge/Terraform-1.7+-7B42BC?logo=terraform)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.29+-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Why this repo exists

Most "Kubernetes on GCP" tutorials show toy apps. This repo demonstrates a **realistic telecom BSS workload** — the kind of system that actually runs revenue-critical operations at carriers like Viettel, VNPT, and Orange.

It is structured as a **learning portfolio**: every component is real, runnable, and explained. Use it to:

- **Learn** how production microservices on GKE actually fit together
- **Showcase** end-to-end platform engineering skills to recruiters
- **Bootstrap** a real BSS modernization project

## Architecture

```
                         ┌───────────────────────────────────┐
                         │         GCP Project               │
                         │                                   │
   Developers ──► GitHub │  ┌─────────────────────────────┐  │
                  Actions│  │  Artifact Registry          │  │
                    │    │  │  (container images)         │  │
                    │    │  └──────────────┬──────────────┘  │
                    │    │                 │ pull             │
                    ▼    │  ┌──────────────▼──────────────┐  │
   ┌────────────────────►│  │  GKE Autopilot Cluster      │  │
   │  Terraform (IaC)    │  │  ┌──────────────────────┐   │  │
   │                     │  │  │  Namespace: bss      │   │  │
   │                     │  │  │   • customer-svc     │   │  │
   │                     │  │  │   • billing-svc      │   │  │
   │                     │  │  │   • product-svc      │   │  │
   │                     │  │  │   • order-svc        │   │  │
   │                     │  │  └──────────────────────┘   │  │
   │                     │  │  ┌──────────────────────┐   │  │
   │                     │  │  │  Namespace: monitor  │   │  │
   │                     │  │  │   • Prometheus       │   │  │
   │                     │  │  │   • Grafana          │   │  │
   │                     │  │  │   • AlertManager     │   │  │
   │                     │  │  └──────────────────────┘   │  │
   │                     │  └─────────────────────────────┘  │
   │                     │  ┌─────────────────────────────┐  │
   │                     │  │  Cloud SQL (PostgreSQL)     │  │
   │                     │  └─────────────────────────────┘  │
   │                     └───────────────────────────────────┘
   │
   └── VPC, Subnets, IAM, Workload Identity, Private Cluster
```

## What's inside

| Folder | Component | Tech |
|---|---|---|
| `terraform/` | GCP infrastructure as code | Terraform 1.7, GCP provider 5.x |
| `services/` | BSS microservices | Spring Boot 3, Java 21 |
| `kubernetes/` | K8s manifests (Kustomize) | Kubernetes 1.29 |
| `monitoring/` | Observability stack | Prometheus, Grafana, AlertManager |
| `.github/workflows/` | CI/CD pipelines | GitHub Actions |
| `docs/` | Setup guides & ADRs | Markdown |

## Microservices (TM Forum-aligned)

The BSS domain is modeled loosely after **TM Forum Open APIs**, the industry standard for telecom operations:

| Service | Responsibility | TM Forum API |
|---|---|---|
| `customer-service` | Customer lifecycle, identity, contacts | TMF629 |
| `product-catalog` | Plans, offers, pricing | TMF620 |
| `order-management` | Order capture and orchestration | TMF622 |
| `billing-service` | Charging, invoicing, payment | TMF678 |

> Only `customer-service` is implemented in this repo as the reference. The other three follow the same pattern — implementing them is part of the learning roadmap (see [docs/ROADMAP.md](docs/ROADMAP.md)).

## Quick start

**Prerequisites:** `gcloud`, `terraform`, `kubectl`, `docker`, a GCP project with billing enabled.

```bash
# 1. Bootstrap GCP infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit with your project_id
terraform init
terraform apply

# 2. Connect kubectl to the new cluster
gcloud container clusters get-credentials bss-cluster --region asia-southeast1

# 3. Deploy the monitoring stack
kubectl apply -f monitoring/

# 4. Deploy the customer service
kubectl apply -k kubernetes/overlays/dev

# 5. Open the Grafana dashboard
kubectl port-forward -n monitoring svc/grafana 3000:80
# → http://localhost:3000
```

Full step-by-step instructions in [docs/SETUP.md](docs/SETUP.md).

## Cost warning

Running this on GCP costs roughly **$5–10 USD per day** with default settings (GKE Autopilot + Cloud SQL + load balancer). Always `terraform destroy` when not actively learning. Better yet, follow the cost-optimized config in [docs/SETUP.md](docs/SETUP.md#cost-optimization).

## Learning roadmap

This repo is designed to be built up, not just cloned. See [docs/ROADMAP.md](docs/ROADMAP.md) for the 6-week structured learning path.

## License

MIT — see [LICENSE](LICENSE).

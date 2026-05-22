# BSS Platform — Executive Summary

Hệ thống Business Support System (BSS) chuẩn viễn thông, kiến trúc microservices, triển khai trên **AWS EKS**.

> Đây là bản tóm tắt 1 trang. Chi tiết kiến trúc + lộ trình + quy ước đầy đủ trong **[CLAUDE.md](CLAUDE.md)**.

---

## Cái nhìn 1 phút

```
Frontend (Vite+React)  →  ALB  →  API Gateway  →  4 Spring Boot services  →  RDS / EventBridge / SQS
        ↑                                ↑
   web-portal                      customer / product
   admin-console                   order   / billing
```

| | |
|---|---|
| **Cloud** | AWS (region: ap-southeast-1) |
| **Orchestration** | EKS Managed Node Groups + Karpenter |
| **Backend** | Java 21, Spring Boot 3.2 |
| **Frontend** | Vite + React + TypeScript |
| **DB** | RDS PostgreSQL (schema-per-service) |
| **Events** | EventBridge + SQS |
| **IaC** | Terraform 1.7 |
| **CI/CD** | GitHub Actions + OIDC |
| **Observability** | Prometheus + Grafana + CloudWatch + X-Ray |
| **Environments** | dev, staging, prod (tách hoàn toàn) |

---

## Microservices (TM Forum-aligned)

| Service | TMF | Trạng thái |
|---|---|---|
| customer-service | TMF629 | Có CRUD scaffold |
| product-catalog  | TMF620 | Placeholder |
| order-management | TMF622 | Placeholder + EventBridge publisher |
| billing-service  | TMF678 | Placeholder + SQS consumer |
| api-gateway      | —      | Routes configured |

---

## Lộ trình (10 phase)

1. **Chuẩn bị** — cài tooling, tạo AWS account
2. **Local dev** — chạy local với docker-compose + LocalStack
3. **AWS bootstrap** — S3 tfstate + budget alert
4. **Deploy dev infra** — Terraform apply, install cluster addons
5. **Deploy first service** — push lên ECR, apply Kustomize overlay
6. **Wire CI/CD** — GitHub Actions chạy auto
7. **Hoàn thiện 4 service nghiệp vụ + frontend UI thật**
8. **Observability** — Prometheus + alerts + X-Ray
9. **Staging + Prod** — tag-based promotion
10. **Hardening** — WAF, NetworkPolicy, chaos test, postmortem doc

---

## Chi phí ước tính (USD/ngày)

| Env | Cost |
|---|---|
| Dev | ~$5 (`tf-destroy` mỗi tối → 0$) |
| Staging | ~$9 |
| Prod | ~$30+ |

⚠️ NAT Gateway tốn $1.10/ngày → dev dùng **VPC Endpoints** thay thế.

---

## Bắt đầu trong 3 lệnh

```bash
# 1. Khởi động stack local
make local-up

# 2. Chạy customer-service local
cd apps/backend/customer-service && mvn spring-boot:run

# 3. Hit endpoint
curl http://localhost:8080/actuator/health
```

Khi sẵn sàng deploy AWS:

```bash
make bootstrap                      # tạo S3 tfstate + budget
make ENV=dev tf-init tf-apply       # provision dev infra (~20 phút)
make ENV=dev kube-config
```

Xem chi tiết trong [docs/SETUP.md](docs/SETUP.md).

---

## Liên kết

- [CLAUDE.md](CLAUDE.md) — kế hoạch + quy ước đầy đủ
- [README.md](README.md) — public-facing repo intro
- [docs/ROADMAP.md](docs/ROADMAP.md) — lộ trình học theo tuần
- [platform/README.md](platform/README.md) — Helm install sequence cho cluster addons
- [deploy/README.md](deploy/README.md) — local docker-compose stack

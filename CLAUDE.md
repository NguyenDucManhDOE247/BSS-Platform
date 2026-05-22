# CLAUDE.md — BSS Platform (AWS / EKS)

> File này là **bản kế hoạch tổng thể** + **bộ quy ước làm việc** cho Claude Code khi tương tác với repo này. Mọi quyết định kiến trúc, công nghệ, quy ước code và lộ trình triển khai đều ở đây.

---

## 1. Mục tiêu

Xây dựng một **Business Support System (BSS)** chuẩn viễn thông theo kiến trúc **microservices**, triển khai trên **Amazon EKS**, vận hành bằng **Terraform IaC**, có **CI/CD tự động** qua GitHub Actions, và **observability** đầy đủ (Prometheus + Grafana + CloudWatch + X-Ray).

Mục đích kép: **portfolio học tập platform-engineering** + **tham chiếu kiến trúc** có thể mở rộng thành BSS thật.

---

## 2. Kiến trúc tổng thể (5 lớp + Platform)

```
┌─────────────────────────────────────────────────────────────────┐
│ LỚP 1  Người dùng (web/mobile/B2B)                              │
└─────────────────────────────────────────────────────────────────┘
                            │ HTTPS
┌─────────────────────────────────────────────────────────────────┐
│ LỚP 2  Edge:  CloudFront → ALB → AWS WAF                        │
└─────────────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────────────┐
│ LỚP 3  Frontend  (chạy trên EKS):                               │
│   • web-portal      Vite + React + Nginx                        │
│   • admin-console   Vite + React + Nginx                        │
└─────────────────────────────────────────────────────────────────┘
                            │ REST
┌─────────────────────────────────────────────────────────────────┐
│ LỚP 4  Backend  (chạy trên EKS):                                │
│   • api-gateway      Spring Cloud Gateway                       │
│   • customer-service  TMF629                                    │
│   • product-catalog   TMF620                                    │
│   • order-management  TMF622  ──publish──> EventBridge          │
│   • billing-service   TMF678  <──consume── SQS                  │
└─────────────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────────────┐
│ LỚP 5  Data:                                                    │
│   • RDS PostgreSQL  (schema per service)                        │
│   • ElastiCache Redis (cache, optional)                         │
│   • EventBridge + SQS (event bus)                               │
│   • S3 (file/blob)                                              │
└─────────────────────────────────────────────────────────────────┘

         ▲ CẮT NGANG ▲
┌─────────────────────────────────────────────────────────────────┐
│ PLATFORM:                                                       │
│   • EKS cluster (Managed Node Groups + Karpenter cho workload)  │
│   • VPC, IAM (IRSA), Secrets Manager                            │
│   • Prometheus + Grafana (in-cluster)                           │
│   • Fluent Bit → CloudWatch Logs                                │
│   • OTel Collector → X-Ray                                      │
│   • AWS LB Controller, ExternalDNS, Secrets Store CSI           │
│   • GitHub Actions OIDC → IAM Role (no static keys)             │
└─────────────────────────────────────────────────────────────────┘
```

### Tại sao chọn từng thành phần?

| Vai trò | Lựa chọn | Lý do |
|---|---|---|
| Cloud | **AWS** | Job market lớn ở VN, ecosystem trưởng thành, free-tier tốt năm 1 |
| Orchestration | **EKS Managed Node Groups + Karpenter** | Production-realistic, Karpenter tự provision spot rẻ hơn ~70% |
| Backend | **Java 21 + Spring Boot 3.2** | Telco VN dùng Java; Spring Cloud Gateway / Boot 3 ecosystem chuẩn |
| Frontend | **Vite + React + TypeScript** | Vite build nhanh, React phổ biến, dễ tuyển; SSR có thể thêm sau |
| DB | **RDS PostgreSQL** | Managed, có HA, IAM auth, PITR; 1 instance dùng chung schema-per-service |
| Cache | **ElastiCache Redis** | (Thêm khi cần) — sub-ms latency |
| Event bus | **EventBridge + SQS** | EventBridge routing rules + SQS per-consumer + DLQ; rẻ, không cần nuôi Kafka |
| Storage | **S3** | Standard |
| Container | **ECR** | Tích hợp sẵn IAM, image scan |
| IaC | **Terraform 1.7 + hashicorp/aws 5.x** | Tiêu chuẩn ngành |
| K8s pkg | **Kustomize** | Built-in `kubectl`, đủ cho 7 service, không cần Helm phức tạp |
| CI/CD | **GitHub Actions + OIDC** | Free public repo, không cần JSON key |
| Monitoring | **kube-prometheus-stack (in-cluster)** | Source of truth cho metric; CloudWatch chỉ cho log + AWS-native metrics |
| Tracing | **OTel + X-Ray** | Vendor-neutral instrument; export sang X-Ray |
| Secrets | **AWS Secrets Manager + Secrets Store CSI** | Pod mount secret, không cần env var với plain text |
| Service mesh | **Không dùng (đến khi >10 services)** | Istio quá nặng cho 7 service; bật khi cần mTLS/traffic shaping |

> **Nguyên tắc:** không over-engineer. Spinnaker, ArgoCD, Argo Rollouts, multi-region, MSK — đều **để dành** đến khi có nhu cầu rõ.

---

## 3. Domain — BSS theo TM Forum Open APIs

| Service | Trách nhiệm | TMF API | Trạng thái |
|---|---|---|---|
| `customer-service` | Vòng đời khách hàng, identity | **TMF629** | ✅ Có scaffold CRUD |
| `product-catalog` | Plans, offers, pricing | **TMF620** | 🚧 Placeholder controller |
| `order-management` | Order capture + orchestration | **TMF622** | 🚧 Placeholder + EventBridge publisher |
| `billing-service` | Charging, invoicing, payment | **TMF678** | 🚧 Placeholder + SQS consumer |
| `api-gateway` | Routing, auth, rate-limit | — | 🚧 Routes configured |

### Tương tác giữa service

- **Sync (REST):** customer ← product ← order (đọc tham chiếu, qua API Gateway).
- **Async (EventBridge → SQS):** order → billing (event `OrderCompleted`).
- **Database-per-service:** mỗi service một schema riêng trên cùng 1 RDS instance (Phase ≤ 6). Tách instance khi >100 QPS hoặc cần isolation cứng.

### Contract & versioning

- OpenAPI 3.1 spec trong `packages/api-contracts/`.
- URI versioning: `/tmf-api/customerManagement/v4/...`.
- Backward-compatible only — thêm trường, deprecate trước 1 release rồi mới xóa.

---

## 4. Hai chiều: Services × Environments

```
                  ┌─────────┐   ┌─────────┐   ┌─────────┐
                  │   DEV   │   │ STAGING │   │  PROD   │
                  └─────────┘   └─────────┘   └─────────┘
customer-service     SHA            rc-vX           vX
product-catalog      SHA            rc-vX           vX
order-management     SHA            rc-vX           vX
billing-service      SHA            rc-vX           vX
api-gateway          SHA            rc-vX           vX
web-portal           SHA            rc-vX           vX
admin-console        SHA            rc-vX           vX
```

### Sizing per env

| | Dev | Staging | Prod |
|---|---|---|---|
| Region | ap-southeast-1 (Singapore) | ap-southeast-1 | ap-southeast-1 |
| AZs | 2 | 3 | 3 |
| NAT Gateway | ❌ (VPC Endpoints thay thế) | 1 | HA |
| EKS public endpoint | 0.0.0.0/0 | restricted IPs | restricted IPs |
| Node group | t3.medium × 2 | t3.large × 2-5 | t3.large × 3-6 |
| RDS | db.t3.micro single-AZ | db.t3.small single-AZ | db.t3.medium **multi-AZ** |
| Deletion protection | OFF | ON | ON |
| Log retention | 3d | 14d | 30d |
| X-Ray sampling | 50% | 20% | 5% |
| Replicas/service | 1 | 2 | 3+ |
| **Cost ước tính** | **~$5/ngày** | **~$9/ngày** | **~$30+/ngày** |

> ⚠️ NAT Gateway tốn $1.10/ngày — luôn ưu tiên VPC Endpoints khi có thể.

---

## 5. CI/CD chiến lược

### 3 nguyên tắc cốt lõi
1. **Build once, deploy many** — image tag = git SHA, re-tag khi promote (không bao giờ rebuild).
2. **Trunk-based + tag-based promotion** — `main` luôn deployable; tag `rc-vX` → staging; tag `vX` → prod.
3. **Path-filter trigger** — chỉ build service nào đã thay đổi.

### Workflows

| File | Trigger | Hành động |
|---|---|---|
| `ci-backend.yml` | PR đụng `apps/backend/**` | Maven verify + Trivy + docker build (no push) |
| `ci-frontend.yml` | PR đụng `apps/frontend/**` | npm lint/test/build + Trivy + docker build |
| `ci-terraform.yml` | PR đụng `infrastructure/terraform/**` | fmt + tfsec + plan (post comment) |
| `ci-k8s.yml` | PR đụng `infrastructure/kubernetes/**` | kustomize build + kubeconform 3 envs |
| `cd-dev.yml` | Merge `main` | Build + push (tag=SHA) + apply dev overlay + smoke + rollback nếu fail |
| `cd-staging.yml` | Tag `rc-v*` | Re-tag SHA→rc-vX + apply staging + E2E test |
| `cd-prod.yml` | Tag `v[0-9]+.[0-9]+.[0-9]+` | **Manual approval** + re-tag rc→v + apply prod + auto rollback |

### Promotion flow (1 release)

```
Day 1  dev code/merge PR  → cd-dev auto deploy DEV
Day 3  git tag rc-v1.2.0  → cd-staging deploy STAGING (QA test)
Day 5  git tag v1.2.0     → cd-prod chờ approve → rollout PROD
```

### Required GitHub Secrets

| Secret | Mô tả |
|---|---|
| `AWS_DEPLOYER_ROLE_ARN` | IAM role cho dev + staging (tạo bởi Terraform `iam` module) |
| `AWS_PROD_DEPLOYER_ROLE_ARN` | IAM role riêng cho prod (least privilege) |
| `ECR_REGISTRY` | `{account_id}.dkr.ecr.ap-southeast-1.amazonaws.com` |

---

## 6. Cấu trúc thư mục

```
bss-platform/
├── apps/                                ← TẤT CẢ APP CHẠY ĐƯỢC
│   ├── frontend/
│   │   ├── web-portal/                 ← Vite + React + Nginx
│   │   └── admin-console/              ← Vite + React + Nginx
│   └── backend/
│       ├── api-gateway/                ← Spring Cloud Gateway
│       ├── customer-service/           ← TMF629
│       ├── product-catalog/            ← TMF620
│       ├── order-management/           ← TMF622 (+ EventBridge publish)
│       └── billing-service/            ← TMF678 (+ SQS consume)
│
├── packages/                            ← LIBRARY DÙNG CHUNG
│   ├── bss-common-java/                ← DTO, exception, security
│   ├── ui-kit/                         ← React components
│   └── api-contracts/                  ← OpenAPI specs + JSON schemas
│
├── infrastructure/                      ← IaC
│   ├── terraform/
│   │   ├── modules/                    ← Reusable modules
│   │   │   ├── vpc/                    │   • VPC, subnets, VPC Endpoints
│   │   │   ├── eks/                    │   • EKS + IRSA OIDC + addons
│   │   │   ├── rds/                    │   • PostgreSQL + Secrets Manager
│   │   │   ├── ecr/                    │   • Per-service repos + lifecycle
│   │   │   ├── eventbridge/            │   • Bus + per-consumer SQS + DLQ
│   │   │   ├── iam/                    │   • IRSA + GitHub OIDC deployer
│   │   │   └── observability/          │   • CloudWatch log groups + X-Ray
│   │   └── environments/
│   │       ├── dev/
│   │       ├── staging/
│   │       └── prod/
│   │
│   └── kubernetes/
│       ├── base/                       ← Manifests gốc
│       │   ├── customer-service/       │   (deployment, service, sa, hpa, pdb)
│       │   └── ...
│       └── overlays/
│           ├── dev/                    │   (replicas=1, LOG_LEVEL=DEBUG)
│           ├── staging/                │   (replicas=2)
│           └── prod/                   │   (replicas=3, PDB minAvail=2)
│
├── platform/                            ← CLUSTER-WIDE ADDONS (Helm values)
│   ├── monitoring/                     ← kube-prometheus-stack
│   ├── logging/                        ← Fluent Bit → CloudWatch
│   ├── tracing/                        ← OTel Collector → X-Ray
│   ├── secrets/                        ← Secrets Store CSI + SPC examples
│   ├── networking/                     ← ALB Controller, ExternalDNS, Karpenter
│   └── README.md                       ← Helm install sequence
│
├── deploy/                              ← LOCAL DEV
│   ├── docker-compose.yml              ← Postgres + Redis + LocalStack
│   ├── postgres-init/                  ← Tạo 4 database service
│   ├── localstack-init/                ← Tạo EventBridge bus + SQS queue
│   ├── .env.example                    ← Env vars khi chạy service local
│   └── README.md
│
├── .github/workflows/                   ← CI/CD
│   ├── ci-backend.yml
│   ├── ci-frontend.yml
│   ├── ci-terraform.yml
│   ├── ci-k8s.yml
│   ├── cd-dev.yml
│   ├── cd-staging.yml
│   └── cd-prod.yml
│
├── docs/
│   ├── architecture/
│   ├── runbooks/
│   ├── api/
│   ├── adr/                            ← Architecture Decision Records
│   ├── onboarding/
│   ├── ROADMAP.md
│   └── SETUP.md
│
├── scripts/
│   ├── bootstrap-aws.sh                ← One-time S3+DynamoDB+Budget
│   ├── teardown.sh                     ← terraform destroy <env>
│   └── smoke.sh                        ← Hit ALB sau deploy
│
├── CLAUDE.md                            ← (file này)
├── PLAN.md                              ← Tóm tắt cho người
├── README.md                            ← Public-facing
├── Makefile                             ← Shortcut mọi tác vụ
└── LICENSE
```

---

## 7. Coding conventions

### Java / Spring Boot
- Package layout **per feature** (controller/service/repository/model/dto/config), không per layer.
- **Constructor injection**, không `@Autowired` field.
- **Records** cho DTO + value object.
- `@Transactional` chỉ ở service layer.
- Logging SLF4J structured JSON ở prod; không log PII (CCCD, OTP, mật khẩu).
- Validation qua Bean Validation (`@Valid`, `@NotNull`, `@Size`).
- **Flyway migration** `db/migration/V<ts>__<desc>.sql`.
- PK = UUID v7.

### REST API
- Path: `/tmf-api/<resource>Management/v<n>/<resource>` (chuẩn TM Forum).
- HTTP status nghiêm túc: 201/204/409/422.
- Error body theo **RFC 7807 ProblemDetail** (đã có sẵn handler trong `packages/bss-common-java`).
- Pagination: `?offset=0&limit=20`, header `X-Total-Count`.
- Idempotency-Key header cho mọi POST mutating.

### Frontend (React/TS)
- TypeScript **strict mode** — không `any`.
- State: **react-query** cho server state, **zustand** cho local UI state.
- Component layout: `pages/`, `components/`, `hooks/`, `api/` (generated từ OpenAPI).
- Tests: **vitest + @testing-library/react**.

### Kubernetes
- Mỗi service: Deployment + Service + ServiceAccount + HPA + PDB.
- **3 probes bắt buộc:** startup + liveness + readiness.
- Container chạy `runAsNonRoot: true, readOnlyRootFilesystem: true`, drop all caps.
- Image tag = git SHA (không bao giờ `latest`).
- Mọi container có cả `requests` + `limits` (Karpenter cần để chọn instance đúng).

### Terraform
- `terraform fmt && terraform validate` trước commit.
- Module hóa khi tái sử dụng (đã có sẵn 7 module trong `modules/`).
- Resource cost cao (HA RDS, GPU, MSK) → cảnh báo trong PR description.
- Secret không vào `.tfvars` — sinh random → Secrets Manager.

---

## 8. Lộ trình triển khai theo Phase

### Phase 0 — Chuẩn bị
- [x] Cấu trúc monorepo + scaffold đầy đủ 7 service (4 backend + 1 gateway + 2 frontend).
- [x] Terraform modules + 3 environments.
- [x] CI/CD 7 workflows.
- [x] Local dev với docker-compose + LocalStack.
- [ ] **Tạo AWS account** + bật billing + MFA + budget alert.
- [ ] Cài `aws-cli`, `terraform 1.7+`, `kubectl`, `helm`, `kustomize`, `docker`, `jdk 21`, `node 20`.

### Phase 1 — Local development
- [ ] `make local-up` → verify Postgres + LocalStack chạy.
- [ ] Chạy `customer-service` local (`mvn spring-boot:run` với `.env.example`).
- [ ] Hit CRUD endpoints bằng curl/Postman.
- [ ] Chạy `web-portal` (`npm run dev`) → test gọi qua Vite proxy.
- [ ] Bổ sung Flyway migration thật + Testcontainers integration test.

### Phase 2 — AWS account bootstrap
- [ ] `aws configure` với credentials (tạo IAM user dùng cho personal, MFA bật).
- [ ] `./scripts/bootstrap-aws.sh` → tạo S3 tfstate + DynamoDB locks + budget.
- [ ] Edit `infrastructure/terraform/environments/dev/main.tf` → uncomment `backend "s3"`.
- [ ] `make ENV=dev tf-init && make ENV=dev tf-plan`.

### Phase 3 — Deploy infrastructure (dev)
- [ ] `make ENV=dev tf-apply` (mất ~15-20 phút lần đầu cho EKS).
- [ ] `make ENV=dev kube-config` → `kubectl get nodes`.
- [ ] Cài cluster addons theo `platform/README.md` (Helm).
- [ ] Verify ALB Controller + ExternalDNS chạy.

### Phase 4 — Deploy first service
- [ ] `make ENV=dev SERVICE=customer-service push` → image lên ECR.
- [ ] `make ENV=dev SERVICE=customer-service set-image deploy`.
- [ ] `make ENV=dev smoke` → ALB trả 200.

### Phase 5 — CI/CD wiring
- [ ] Push repo lên GitHub.
- [ ] GitHub Settings → Secrets thêm `AWS_DEPLOYER_ROLE_ARN` (từ `terraform output github_deployer_role_arn`).
- [ ] Mở PR sửa nhỏ → verify `ci-backend` chạy + pass.
- [ ] Merge → verify `cd-dev` deploy thành công.

### Phase 6 — Hoàn thiện service nghiệp vụ
- [ ] Implement TMF620 trong `product-catalog`.
- [ ] Implement TMF622 trong `order-management` + viết integration test EventBridge publish.
- [ ] Implement TMF678 trong `billing-service` + SQS consumer idempotent.
- [ ] Implement frontend UI thật cho web-portal (đăng ký gói, xem hóa đơn).

### Phase 7 — Observability hoàn chỉnh
- [ ] Cài Prometheus + Grafana qua Helm.
- [ ] Import dashboard từ `platform/monitoring/grafana/dashboards/`.
- [ ] Cấu hình OTel agent trong từng service Java (auto-instrument).
- [ ] Define SLI/SLO trong `docs/SLO.md`.
- [ ] Wire alerts → Slack/Discord webhook.

### Phase 8 — Staging + prod
- [ ] `make ENV=staging tf-apply`.
- [ ] Tag `rc-v0.1.0` → verify cd-staging.
- [ ] `make ENV=prod tf-apply` (với public_access_cidrs restricted thật).
- [ ] Tag `v0.1.0` → approve trong GitHub UI → verify cd-prod.

### Phase 9 — Production hardening
- [ ] Bật **AWS WAF** trước ALB.
- [ ] **NetworkPolicy** mặc định deny + whitelist từng cặp service.
- [ ] **Pod Security Standards: restricted** ở namespace `bss`.
- [ ] Chaos test: `kubectl delete pod` ngẫu nhiên + verify recovery.
- [ ] Multi-AZ verification — fail 1 AZ → cluster vẫn serve.

### Phase 10 — Đánh bóng portfolio
- [ ] Viết `docs/POSTMORTEMS.md` về bug khó nhất.
- [ ] Video demo 5 phút (deploy → break → recover).
- [ ] Blog post "Building a telecom BSS on AWS EKS".
- [ ] Mời 1-2 senior review, xử lý feedback.

---

## 9. Quy ước cho Claude khi làm việc với repo này

### Nguyên tắc chung
- **Bám lộ trình Phase.** Không nhảy cóc nếu user chưa khẳng định.
- **Hỏi trước khi tốn tiền.** Bất kỳ `terraform apply`, `aws ... create`, `kubectl create` đụng AWS thật → confirm trước.
- **Không commit secret.** `.env`, `.tfvars`, AWS credentials → trong `.gitignore`.
- **Mọi `terraform apply` đi kèm `plan` để user duyệt.**
- Khi user mơ hồ — hỏi 1 câu làm rõ, không đoán.

### Khi tạo backend service mới
1. Copy cấu trúc từ `customer-service` hoặc `product-catalog`.
2. Đổi `groupId`/`artifactId` trong `pom.xml`, package `com.bss.<svc>`, DB schema.
3. Tạo Flyway migration `V1__init_<svc>.sql`.
4. Tối thiểu: 1 controller, 1 service, 1 repo, 1 entity, 1 DTO, 1 integration test.
5. Thêm K8s base manifests vào `infrastructure/kubernetes/base/<svc>/`.
6. Thêm vào `infrastructure/kubernetes/base/kustomization.yaml`.
7. Thêm IRSA role vào `infrastructure/terraform/environments/*/main.tf` (mục `services`).

### Khi sửa Terraform
1. `terraform fmt && terraform validate` trước commit.
2. Resource có cost cao → cảnh báo trong PR description.
3. Update `docs/SETUP.md` nếu có resource mới cần config.

### Khi viết K8s manifest
1. Thêm vào `infrastructure/kubernetes/base/<svc>/`, không thêm thẳng overlay.
2. Mọi container: resources + 3 probes + securityContext non-root.
3. Image tag dùng placeholder, Kustomize `images:` set tag.

### Khi viết test
- Bug fix → kèm test reproduce (fail trước, pass sau).
- Feature → unit test happy path + ≥2 edge case + integration test contract.
- Không mock framework (Spring, JPA, AWS SDK) ở integration test — dùng Testcontainers + LocalStack.

### Trả lời câu hỏi
- User người Việt — trả lời tiếng Việt, giữ thuật ngữ kỹ thuật tiếng Anh.
- Giải thích lựa chọn kiến trúc → luôn nói rõ **trade-off**, không chỉ ưu điểm.
- User nói "build cái này đi" → kiểm tra Phase hiện tại; nếu vượt Phase → đề xuất chia nhỏ.

---

## 10. Best practices ràng buộc

### Security
- ❌ Không có AWS access key trong repo/local/CI (mọi xác thực qua IRSA hoặc OIDC).
- ❌ Không có secret cleartext trong manifest hay env var (Secrets Manager + CSI).
- ❌ Không log PII, password, OTP, token, CCCD.
- ✅ Mọi image qua Trivy trong CI; fail nếu HIGH/CRITICAL chưa fix.
- ✅ Pod chạy non-root, readOnly root FS, drop all caps.
- ✅ EKS public endpoint **restricted** ở prod.
- ✅ ECR repo `IMMUTABLE` tags.

### Reliability
- ✅ ≥2 replica ở prod, PDB minAvailable ≥ 1.
- ✅ HPA dựa CPU + custom metric (req/s) khi sẵn sàng.
- ✅ Mọi external call (DB, SQS, REST) có timeout + retry + circuit breaker (Resilience4j).
- ✅ SLI/SLO + error budget burn-rate alert.

### Cost
- ✅ Dev cluster `make ENV=dev tf-destroy` mỗi tối.
- ✅ Dev: t3.micro RDS, t3.medium nodes, không HA.
- ✅ VPC Endpoints thay NAT Gateway (tiết kiệm $1.10/ngày).
- ✅ ECR lifecycle policy auto-xóa image cũ.
- ⚠️ Budget alert ở `$30/tháng` cho dev — cảnh báo nếu vượt.

### Operability
- ✅ Mọi service expose `/actuator/health`, `/actuator/prometheus`.
- ✅ Mỗi service có Grafana dashboard riêng (4 RED + saturation).
- ✅ Mọi alert có `runbook_url` annotation.
- ✅ Log JSON ở prod, có `trace_id` correlate với X-Ray.

---

## 11. Lệnh thường dùng (cheatsheet)

```bash
make help                                    # liệt kê target

# Bootstrap (1 lần per account)
make bootstrap                               # S3 tfstate + DynamoDB locks + budget

# Local dev
make local-up                                # Postgres + Redis + LocalStack
cd apps/backend/customer-service && mvn spring-boot:run
cd apps/frontend/web-portal && npm run dev

# Infrastructure (ENV=dev|staging|prod)
make ENV=dev tf-init
make ENV=dev tf-plan
make ENV=dev tf-apply                        # cần confirm!
make ENV=dev tf-destroy                      # nightly để tiết kiệm

# Cluster access
make ENV=dev kube-config

# Build + deploy single service
make ENV=dev SERVICE=customer-service push
make ENV=dev SERVICE=customer-service set-image deploy
make ENV=dev smoke

# Promote
git tag rc-v0.1.0 && git push --tags         # → cd-staging
git tag v0.1.0 && git push --tags            # → cd-prod (manual approval)
```

---

## 12. Tài liệu tham khảo

- **TM Forum Open APIs** — https://www.tmforum.org/oda/open-apis/
- **EKS Best Practices Guide** — https://aws.github.io/aws-eks-best-practices/
- **IRSA** — https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- **GitHub OIDC + AWS** — https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
- **Karpenter docs** — https://karpenter.sh/
- **Spring Boot 3.2** — https://docs.spring.io/spring-boot/docs/3.2.x/reference/html/
- **Kustomize** — https://kubectl.docs.kubernetes.io/guides/introduction/kustomize/
- **SRE Workbook — SLO chapter** — https://sre.google/workbook/implementing-slos/

---

## 13. Trạng thái hiện tại (cập nhật khi chuyển Phase)

- **Ngày khởi tạo:** 2026-05-22
- **Phase hiện tại:** 0 → 1 (chuẩn bị môi trường local + cài dependencies)
- **AWS account:** chưa tạo
- **Ngân sách dev/tháng mục tiêu:** < $50 USD
- **Người maintain:** chủ repo (1 người, học part-time)

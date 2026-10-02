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
| Orchestration | **EKS Managed Node Groups + Karpenter (dev)** | Production-realistic; Karpenter tự thêm node Spot khi thiếu chỗ (đo thật: Spot −53%, node Ready ~36s — ADR-010). Staging/prod giữ node group cố định (ADR-006) |
| Backend | **Java 21 + Spring Boot 3.5** | Telco VN dùng Java; Spring Cloud Gateway / Boot 3 ecosystem chuẩn (3.5.16 + ghi đè patch Tomcat/Jackson/pgjdbc/Netty → 0 CVE HIGH/CRITICAL) |
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
| Identity | **Keycloak (OIDC) + PKCE** | Cùng realm ở kind/compose/AWS; Cognito không chạy được local (ADR-008) |
| Service mesh | **Không dùng (đến khi >10 services)** | Istio quá nặng cho 7 service; bật khi cần mTLS/traffic shaping |

> **Nguyên tắc:** không over-engineer. Spinnaker, ArgoCD, Argo Rollouts, multi-region, MSK — đều **để dành** đến khi có nhu cầu rõ.

---

## 3. Domain — BSS theo TM Forum Open APIs

| Service | Trách nhiệm | TMF API | Trạng thái |
|---|---|---|---|
| `customer-service` | Vòng đời khách hàng, identity | **TMF629** | ✅ CRUD + PATCH, `/customer/me` (hồ sơ gắn `sub` Keycloak), admin duyệt/khóa, Flyway, IT |
| `product-catalog` | Plans, offers, pricing | **TMF620** | ✅ Offering + Category + Specification; admin sửa giá/ngừng bán, khách chỉ thấy gói `Active` |
| `order-management` | Order capture + orchestration | **TMF622** | ✅ **transactional outbox** → EventBridge; khách lấy từ token, phải `Active`, giá từ catalog |
| `billing-service` | Charging, invoicing, payment | **TMF678** | ✅ Invoice (VAT 10%) + **idempotent SQS consumer**; khách chỉ thấy hóa đơn của mình; doanh thu cho admin |
| `api-gateway` | Routing, auth, rate-limit | — | ✅ Spring Cloud Gateway + OAuth2 Resource Server (chặn thô; mỗi service tự kiểm JWT) |

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
| Node group | t3.medium × 2 + Karpenter Spot (≤ 8 vCPU) | t3.large × 3 | t3.large × 4 (vừa quota 8 vCPU) |
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
1. **Build once, deploy many** — image tag = SHA của commit cuối chạm thư mục service; promote = `aws ecr put-image` gắn thêm tag `rc-vX`/`vX` lên cùng digest (không bao giờ rebuild). Nguồn sự thật phiên bản: ADR-005.
2. **Trunk-based + tag-based promotion** — `main` luôn deployable; tag `rc-vX` → staging; tag `vX` → prod.
3. **Path-filter trigger** — chỉ build service nào đã thay đổi.

### Workflows

| File | Trigger | Hành động |
|---|---|---|
| `ci-backend.yml` | PR đụng `apps/backend/**` | Maven verify + Trivy + docker build (no push) |
| `ci-frontend.yml` | PR đụng `apps/frontend/**` | npm lint/test/build + Trivy + docker build |
| `ci-terraform.yml` | PR đụng `infrastructure/terraform/**` | fmt + tfsec + plan (post comment) |
| `ci-k8s.yml` | PR đụng `infrastructure/kubernetes/**` | kustomize build + kubeconform 3 envs |
| `ci-keycloak.yml` | PR đụng `apps/identity/keycloak/**` | docker build + Trivy + chạy thật 2 replica rootfs chỉ đọc (ADR-011) |
| `ci-scripts.yml` | PR đụng `scripts/**` | shellcheck + test `release-manifest.sh` / `smoke.sh` |
| `cd-dev.yml` | Merge `main` / thủ công | plan (desired từ git) → build service thiếu image → apply manifest 7 service + smoke thật → PASS thì ghi `deploy-state`; hỏng thì rollback về manifest cũ (ADR-005) |
| `cd-staging.yml` | Tag `rc-vX.Y.Z` | Tag phải trên `main` → `ecr put-image` rc-vX → apply staging + smoke → ghi `releases/rc-vX.json` (`verified_in: staging`) |
| `cd-prod.yml` | Tag `vX.Y.Z` | Cổng kiểm (rc đã qua staging, cùng commit) → **Approve thủ công** → `ecr put-image` vX → apply prod + smoke; hỏng thì tự rollback |

### Promotion flow (1 release)

```
Day 1  dev code/merge PR  → cd-dev auto deploy DEV
Day 3  git tag rc-v1.2.0  → cd-staging deploy STAGING (QA test)
Day 5  git tag v1.2.0     → cd-prod chờ approve → rollout PROD
```

### GitHub Environments & Variables (không có secret nào — B-39)

Không có AWS access key/secret trong GitHub. Mỗi role AWS chỉ tin **một GitHub Environment**
(`sub` = `repo:<owner>/<repo>:environment:<tên>`). Tạo bằng `scripts/setup-github-environments.sh --apply`.

| Environment | Deploy được từ | Duyệt tay | Variable `AWS_ROLE_ARN` = |
|---|---|---|---|
| `dev` | nhánh `main` | không | `bss-github-deployer-dev` |
| `staging` | tag `rc-v*` | không | `bss-github-deployer-staging` |
| `production` | tag `v*` | **có** | `bss-github-deployer-prod` |

Repository variable `ECR_REGISTRY` = `{account_id}.dkr.ecr.ap-southeast-1.amazonaws.com` (không phải bí mật).

---

## 6. Cấu trúc thư mục

```
bss-platform/
├── apps/                                ← TẤT CẢ APP CHẠY ĐƯỢC
│   ├── frontend/
│   │   ├── web-portal/                 ← Vite + React + Nginx
│   │   └── admin-console/              ← Vite + React + Nginx
│   ├── identity/
│   │   └── keycloak/                   ← Image Keycloak optimized cho AWS (ADR-011)
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
│   ├── ci-keycloak.yml                 ← build + Trivy + chạy thử 2 replica (ADR-011)
│   ├── ci-scripts.yml                  ← shellcheck + test release-manifest/smoke
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
- PK = UUID v7: `@Id @UuidGenerator(algorithm = UuidV7Generator.class)` (bss-common-java — Hibernate 6.6 chưa có sẵn v7).
- Code dùng chung (handler RFC 7807, `NotFoundException`, `OffsetPageRequest`, `CurrentCaller`, `UuidV7`) nằm ở
  `packages/bss-common-java` và được `@Import` — **không chép vào service** (B-15). Đổi thư viện = bump version.

### REST API
- Path: `/tmf-api/<resource>Management/v<n>/<resource>` (chuẩn TM Forum).
- HTTP status nghiêm túc: 201/204/409/422.
- Error body theo **RFC 7807 ProblemDetail** (đã có sẵn handler trong `packages/bss-common-java`).
- Pagination: `?offset=0&limit=20`, header `X-Total-Count`.
- PATCH = **JSON Merge Patch đúng RFC 7396**: không gửi = giữ nguyên, `null` = xóa (trường bắt buộc → 422). DTO dùng
  `JsonNullable<T>` — `Optional<T>` trong record KHÔNG phân biệt được "không gửi" với `null`.
- `Idempotency-Key` (B-15): bắt buộc hỗ trợ ở POST tạo thứ **tính tiền** hoặc không có khóa tự nhiên — hiện là
  `productOrder`. Các POST còn lại tự idempotent nhờ UNIQUE (`/customer/me` theo `sub`, email) hoặc chỉ admin gọi.
  Thêm POST mới thuộc loại đầu → phải hỗ trợ header này (mẫu: order-management `IdempotencyKey`).

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
- [ ] `./scripts/setup-github-environments.sh --apply` (3 Environment + variable `AWS_ROLE_ARN`/`ECR_REGISTRY` — không còn secret).
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
- **Spring Boot 3.5** — https://docs.spring.io/spring-boot/3.5/
- **Kustomize** — https://kubectl.docs.kubernetes.io/guides/introduction/kustomize/
- **SRE Workbook — SLO chapter** — https://sre.google/workbook/implementing-slos/

---

## 13. Trạng thái hiện tại (cập nhật khi chuyển Phase)

> ⚠️ Mục này chỉ tóm tắt. Chi tiết đầy đủ từng buổi làm việc, từng bug thật, từng lệnh đã chạy nằm
> trong `learning/nhat-ky-hoc-tap.md` và `learning/20-lo-trinh-hoan-thanh.md` (cả hai **chỉ tồn tại
> local**, không commit lên git — xem `.gitignore`). File này là bản public, súc tích; nhật ký local
> là bản đầy đủ dùng để học lại.

- **Ngày khởi tạo:** 2026-05-22 — dự án được dựng ban đầu (scaffold) trong ~1 tuần cùng Claude Code.
- **Ngày tiếp nhận:** repo được người maintain hiện tại (không phải người dựng scaffold ban đầu)
  tiếp nhận, kiểm chứng lại toàn bộ từ đầu, và tách hẳn khỏi repo gốc — xem
  `learning/01-hien-trang-va-danh-sach-loi.md` cho danh sách đầy đủ lỗi phát hiện lúc tiếp nhận.
- **Phase hiện tại: 9 hoàn thành → `v2.0.0` (sản phẩm có danh tính thật, chạy trên cả dev/staging/prod),
  và đợt "dọn nợ" từ Phase 8 về 0 đã xong.** Mọi phase đã **hoàn thành và kiểm chứng thật** trên hạ tầng thật
  (không chỉ code) — xem [docs/ROADMAP.md](docs/ROADMAP.md) cho bảng public, bảng dưới cho bằng chứng.
- **AWS account:** đã tạo, MFA bật, Budget alert theo dõi (ngân sách dev mục tiêu **< $50/tháng**,
  không chạy 24/7 — mọi environment dựng theo buổi rồi `terraform destroy`, xem
  [ADR-002](docs/adr/ADR-002-mang-dev.md), [ADR-006](docs/adr/ADR-006-staging-prod-ephemeral.md)).
- **Repo:** `NguyenDucManhDOE247/BSS-Platform` — **không phải fork**, độc lập hoàn toàn với repo gốc.
- **Người maintain:** chủ repo (1 người, học part-time, ~10–12h/tuần theo nhịp
  `learning/20-lo-trinh-hoan-thanh.md`).

### Bằng chứng theo Phase (mỗi dòng = đã chạy thật, không phải suy đoán từ đọc code)

| Phase | Trạng thái | Bằng chứng chính |
|---|---|---|
| 0 — Scaffold | ✅ | Monorepo, 7 module Terraform, CI/CD 7 workflow, docker-compose + LocalStack |
| 1 — Local end-to-end | ✅ | `scripts/e2e-local.sh` PASS; đặt hàng thật qua trình duyệt → hóa đơn VAT đúng 10% |
| 2 — K8s local (`kind`) + observability | ✅ | `scripts/e2e-kind.sh` PASS; k6 50 VU → HPA scale tới `maxReplicas`, giảm lại sau 5 phút |
| 3 — CI xanh trên GitHub | ✅ | 4 workflow xanh với `Tests run > 0` thật; Trivy chặn thật CVE Terraform + image (xem `docs/POSTMORTEMS.md` PM-01 cho bài học về "CI xanh" giả) |
| 4 — Terraform + AWS bootstrap | ✅ | `apply` → `kubectl get nodes` 2 node Ready; `destroy` → 77 resource, xác nhận sạch qua AWS CLI |
| 5 — Deploy dev EKS | ✅ | 7 Pod `Running` trên EKS thật; hóa đơn thật qua ALB → EventBridge → SQS → billing (IRSA thật, B-19) |
| 6 — CD dev/staging/prod | ✅ | 3 lần merge liên tiếp → dev tự deploy đúng; rollback tự động có log thật (2 kịch bản) |
| 7 — Observability + security | ✅ | Dashboard/alert/SLO thật trên `kind`; WAF chặn SQLi + rate-limit thật trên EKS dev (dựng + phá + destroy trong 1 buổi) |
| 8 — Reliability, docs, demo | ✅ | k6 threshold, chaos (pod delete/drain node), `tools/ops/`, blog/demo có số đo thật; Karpenter làm thật ở dọn nợ (ADR-010) |
| 9 — Sản phẩm hoàn chỉnh (danh tính) | ✅ | Keycloak + PKCE, khách tự đăng ký → admin duyệt → mua, quyền sở hữu 4 service (ADR-008); Playwright 3/3 + `e2e-kind.sh` trên kind; Keycloak trên EKS, `rc-v2.0.0` → staging → `v2.0.0` → prod (duyệt tay), smoke có token 4/4 cả 3 môi trường |
| Dọn nợ 8 → 0 | ✅ | Karpenter Spot thật (node Ready ~36s, k6 ×2.4 request); NetworkPolicy EKS 11/11; 8 việc GĐ7 trên 1 cluster (alert → Discord 146s, log JSON + `trace_id` → X-Ray); Spring Boot 3.5 → 0 CVE; schema expand → migrate → contract trên RDS; `orphan_finder.py` bắt 3 loại tài nguyên sót |
| Sau GĐ9 (2026-09-30) | ✅ | Keycloak production-grade trên EKS thật (ADR-011: image optimized, rootfs chỉ đọc, 2 Pod thành cluster qua RDS với NetworkPolicy bật, xóa 1 Pod vẫn giữ session + smoke xanh); auth luôn bật (bỏ `bss.auth.enabled`); rà Definition of Done — xem `docs/ROADMAP.md` |
| HTTPS + tên miền (2026-10-01) | ✅ | `bssplatform.dpdns.org` (ADR-012): zone Route 53 + cert ACM ở shared, ExternalDNS (IAM theo tên bản ghi); dev EKS: TLS 1.3, smoke 7/7 qua HTTPS, NetworkPolicy 12/12, đăng ký + đăng nhập web thật; Keycloak 26.7.5 |

### Quyết định kiến trúc đã chốt kể từ scaffold ban đầu (ADR đầy đủ ở `docs/adr/`)

- **Karpenter chỉ ở dev** — [ADR-010](docs/adr/ADR-010-karpenter-lam-that-o-dev.md) thay
  [ADR-007](docs/adr/ADR-007-karpenter.md) (lúc đầu chọn không dùng). Staging/prod giữ node group cố định.
- **Danh tính: Keycloak + OIDC/PKCE, quyền sở hữu theo `sub`** — [ADR-008](docs/adr/ADR-008-danh-tinh-va-quyen-so-huu.md).
  Quyết định 8 (AWS chưa có HTTPS) đã được [ADR-012](docs/adr/ADR-012-https-ten-mien.md) thay.
- **HTTPS + tên miền `bssplatform.dpdns.org`** — [ADR-012](docs/adr/ADR-012-https-ten-mien.md): zone Route 53 + cert ACM
  wildcard ở state shared, ExternalDNS (quyền theo tên bản ghi), Keycloak ra ALB chỉ `/auth/realms` + `/auth/resources`.
- **Không thêm Jenkins/Helm chart/Ansible** song song với bộ hiện tại — [ADR-009](docs/adr/ADR-009-khong-them-jenkins-helm-ansible.md).
- **Mạng dev dùng NAT Gateway**, không phải VPC Endpoint như dự định ban đầu — [ADR-002](docs/adr/ADR-002-mang-dev.md) (VPC Endpoint vừa không đủ chạy được vừa đắt hơn ở quy mô 2 AZ).
- **3 cluster riêng (dev/staging/prod), nhưng staging/prod ephemeral** (dựng theo buổi) — [ADR-006](docs/adr/ADR-006-staging-prod-ephemeral.md).
- **Keycloak production-grade, CD quản lý như image thứ 8** — [ADR-011](docs/adr/ADR-011-keycloak-production-grade.md).
- **Nguồn sự thật phiên bản CD** = commit git (desired) + release manifest ở nhánh `deploy-state`
  (last-known-good), không phải bot tự commit lại overlay — [ADR-005](docs/adr/ADR-005-nguon-su-that-phien-ban-cd.md).

### Còn lại (có chủ đích để sau — chi tiết ở `learning/20` mục "Để sau")

- ~~HTTPS + đăng nhập web trên AWS~~ — ✅ 2026-10-01 (B-23 + phần web của B-18, #205, [ADR-012](docs/adr/ADR-012-https-ten-mien.md)):
  `https://dev.bssplatform.dpdns.org` thật — TLS 1.3 cert ACM, smoke 7/7 qua HTTPS, NetworkPolicy 12/12, chủ repo tự đăng ký +
  đăng nhập bằng trình duyệt. Staging + prod ✅ 2026-10-02 (`rc-v2.2.0` → `v2.2.0`, smoke 7/7 HTTPS + netpol 12/12 mỗi nơi); prod lộ lỗi
  TXT sở hữu nằm ngoài zone ở apex → sửa `--txt-prefix=extdns-%{record_type}.` (ADR-012).
- **Cert ACM hết hạn 2027-04-17**, chỉ tự gia hạn khi đang gắn vào ALB — xem `docs/runbooks/https-domain.md` mục 4.
- ~~Keycloak production-grade~~ — ✅ 2026-09-30, [ADR-011](docs/adr/ADR-011-keycloak-production-grade.md): image optimized
  `apps/identity/keycloak` (26.7.4 → 26.7.5 ở B-23), rootfs chỉ đọc, prod 2 replica — đã chạy thật trên dev EKS.
- ~~Xóa công tắc `bss.auth.enabled`~~ — ✅ 2026-09-30: auth luôn bật ở mọi môi trường, kể cả `e2e-local.sh`.
- ~~NetworkPolicy ở staging/prod~~ — ✅ 2026-10-01 (B-25, #198): bật `enable_network_policy` cả 2 môi trường;
  `netpol-matrix.sh` 12/12 trên staging và 12/12 trên prod (Keycloak 2 replica, ô JGroups 7800) trong đợt
  release `rc-v2.1.0` → `v2.1.0`.
- **Tỉ lệ lỗi 7,9% dưới tải 700 req/s có Karpenter** — manh mối: `BssPodCrashLooping` của api-gateway
  bắn trong lúc đo (ADR-010).
- ~~B-15~~ — ✅ code xong 2026-10-01 (PR bss-common-java 0.2.0 + PR các service): UUID v7, `Idempotency-Key` cho
  `productOrder`, merge-patch `null` = xóa, 4 service dùng `bss-common-java`. Đóng issue khi 2 PR đã merge.

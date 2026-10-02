# CLAUDE.md — BSS Platform (AWS / EKS)

> File này là **bản kế hoạch tổng thể** + **bộ quy ước làm việc** cho Claude Code khi tương tác với repo này. Mọi quyết định kiến trúc, công nghệ, quy ước code và lộ trình triển khai đều ở đây.

---

## 1. Mục tiêu

Xây dựng một **Business Support System (BSS)** chuẩn viễn thông theo kiến trúc **microservices**, triển khai trên **Amazon EKS**, vận hành bằng **Terraform IaC**, có **CI/CD tự động** qua GitHub Actions, và **observability** đầy đủ (Prometheus + Grafana + CloudWatch + X-Ray).

Mục đích kép: **portfolio học tập platform-engineering** + **tham chiếu kiến trúc** có thể mở rộng thành BSS thật.

---

## 2. Kiến trúc tổng thể (5 lớp + Platform) — **đúng như đang chạy** (2026-10-02)

> Bản vẽ lúc scaffold ([docs/architecture/bss_eks_architecture.png](docs/architecture/bss_eks_architecture.png)) đúng ý
> tưởng tổng thể nhưng có CloudFront và VPC Endpoint thay NAT — hệ thống thật **không** dùng hai thứ đó (ADR-002).
> Sơ đồ dưới đây là bản đúng; mỗi thay đổi so với scaffold có ADR trong `docs/adr/`.

```
┌─────────────────────────────────────────────────────────────────┐
│ LỚP 1  Người dùng: trình duyệt — khách (web-portal), nhân viên  │
│        (admin-console)                                          │
└─────────────────────────────────────────────────────────────────┘
                            │ HTTPS (TLS 1.3, cert ACM) — bssplatform.dpdns.org (ADR-012)
┌─────────────────────────────────────────────────────────────────┐
│ LỚP 2  Edge:  Route 53 (ExternalDNS) → ALB (AWS LB Controller   │
│        tạo từ Ingress) + AWS WAF (SQLi + rate-limit)            │
│        CloudFront: KHÔNG dùng                                   │
└─────────────────────────────────────────────────────────────────┘
                            │  /  /admin  /api  /auth/realms  /auth/resources
┌─────────────────────────────────────────────────────────────────┐
│ LỚP 3  Frontend (EKS): web-portal (/), admin-console (/admin)   │
│        Vite + React + Nginx unprivileged, OIDC/PKCE             │
│        Identity (EKS): Keycloak 26.8.0 — image optimized riêng, │
│        prod 2 replica (ADR-008, ADR-011)                        │
└─────────────────────────────────────────────────────────────────┘
                            │ REST + JWT (mọi service tự kiểm token)
┌─────────────────────────────────────────────────────────────────┐
│ LỚP 4  Backend (EKS):                                           │
│   • api-gateway      Spring Cloud Gateway (chặn thô 401/403)    │
│   • customer-service  TMF629                                    │
│   • product-catalog   TMF620                                    │
│   • order-management  TMF622  ──outbox → EventBridge            │
│   • billing-service   TMF678  <── SQS (idempotent consumer)     │
└─────────────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────────────┐
│ LỚP 5  Data:                                                    │
│   • RDS PostgreSQL 16 — 1 instance, 5 database + 5 user riêng   │
│     (4 service + keycloak; tạo bằng Job db-bootstrap — B-21)    │
│   • EventBridge + SQS + DLQ (event bus)                         │
│   • Secrets Manager (mật khẩu DB từng service, admin Keycloak)  │
│   • Redis: CHƯA dùng (chỉ có trong docker-compose)              │
│   • S3: chỉ cho Terraform state (app không dùng)                │
└─────────────────────────────────────────────────────────────────┘

         ▲ CẮT NGANG ▲
┌─────────────────────────────────────────────────────────────────┐
│ PLATFORM:                                                       │
│   • EKS 1.34: Managed Node Group + Karpenter Spot (CHỈ dev)      │
│   • VPC: 1 NAT Gateway + S3 gateway endpoint (ADR-002)          │
│   • IAM: IRSA từng service, platform-iam cho addon              │
│   • Secrets Store CSI (SecretProviderClass riêng từng service)  │
│   • metrics-server, kube-prometheus-stack (+ Alertmanager →     │
│     Discord), Fluent Bit → CloudWatch, OTel → X-Ray             │
│   • AWS LB Controller, ExternalDNS, StorageClass gp3            │
│   • NetworkPolicy default-deny, Pod Security `restricted`       │
│   • GitHub Actions OIDC → 3 IAM role (không static key)         │
│   • Terraform state `shared` (ECR, OIDC, role, zone, cert) +    │
│     dev/staging/prod — staging/prod ephemeral (ADR-006)         │
└─────────────────────────────────────────────────────────────────┘
```

### Tại sao chọn từng thành phần?

| Vai trò | Lựa chọn | Lý do |
|---|---|---|
| Cloud | **AWS** | Job market lớn ở VN, ecosystem trưởng thành |
| Edge | **ALB + WAF**, không CloudFront | ALB Controller tạo ALB từ chính Ingress; WAF gắn bằng `wire-waf.sh`. CloudFront chưa có nhu cầu (không có nội dung tĩnh toàn cầu) |
| HTTPS + DNS | **Route 53 + ACM + ExternalDNS** | Zone + cert ở state `shared` (sống lâu hơn môi trường); ExternalDNS chỉ ghi được tên của môi trường mình (ADR-012) |
| Orchestration | **EKS Managed Node Groups + Karpenter (dev)** | Production-realistic; Karpenter tự thêm node Spot khi thiếu chỗ (đo thật: Spot −53%, node Ready ~36s — ADR-010). Staging/prod giữ node group cố định (ADR-006) |
| Backend | **Java 21 + Spring Boot 3.5** | Telco VN dùng Java; Spring Cloud Gateway / Boot 3 ecosystem chuẩn (3.5.16 + ghi đè patch Tomcat/Jackson/pgjdbc/Netty → 0 CVE HIGH/CRITICAL) |
| Frontend | **Vite + React + TypeScript** | Vite build nhanh, React phổ biến, dễ tuyển; SSR có thể thêm sau |
| DB | **RDS PostgreSQL 16** | Managed, có HA, PITR (đã khôi phục thật — lab 09); 1 instance, database-per-service |
| Cache | **Redis — chưa dùng** | Load test chưa cho thấy catalog là nút thắt; thêm ElastiCache khi có số đo cần |
| Event bus | **EventBridge + SQS** | EventBridge routing rules + SQS per-consumer + DLQ; rẻ, không cần nuôi Kafka |
| Container | **ECR** | Tích hợp sẵn IAM, image scan, tag `IMMUTABLE`; 8 repo ở state `shared` |
| IaC | **Terraform ≥ 1.10 + hashicorp/aws ~> 5.0** | Tiêu chuẩn ngành; 1.10+ để khóa state bằng S3 `use_lockfile` (không cần DynamoDB) |
| K8s pkg | **Kustomize** | Built-in `kubectl`, đủ cho 8 image; Helm chỉ dùng cài addon (ADR-009) |
| CI/CD | **GitHub Actions + OIDC** | Free public repo, không cần key; nguồn sự thật phiên bản = git + nhánh `deploy-state` (ADR-005) |
| Monitoring | **kube-prometheus-stack (in-cluster)** | Source of truth cho metric; CloudWatch chỉ cho log + AWS-native metrics |
| Tracing | **OTel Java agent + X-Ray** | Vendor-neutral instrument; export sang X-Ray |
| Secrets | **AWS Secrets Manager + Secrets Store CSI** | Pod mount secret, không cần env var với plain text |
| Identity | **Keycloak (OIDC) + PKCE** | Cùng realm ở kind/compose/AWS; Cognito không chạy được local (ADR-008) |
| Service mesh | **Không dùng (đến khi >10 services)** | Istio quá nặng cho 7 service; bật khi cần mTLS/traffic shaping |

> **Nguyên tắc:** không over-engineer. Spinnaker, ArgoCD, Argo Rollouts, multi-region, MSK, Jenkins/Ansible song song
> (ADR-009) — đều **để dành** đến khi có nhu cầu rõ.

---

## 3. Domain — BSS theo TM Forum Open APIs

| Service | Trách nhiệm | TMF API | Trạng thái |
|---|---|---|---|
| `customer-service` | Vòng đời khách hàng, identity | **TMF629** | ✅ CRUD + PATCH, `/customer/me` (hồ sơ gắn `sub` Keycloak), admin duyệt/khóa, Flyway, IT |
| `product-catalog` | Plans, offers, pricing | **TMF620** | ✅ Offering + Category + Specification; admin sửa giá/ngừng bán, khách chỉ thấy gói `Active` |
| `order-management` | Order capture + orchestration | **TMF622** | ✅ **transactional outbox** → EventBridge; khách lấy từ token, phải `Active`, giá từ catalog |
| `billing-service` | Invoicing (chưa có thanh toán — ngoài phạm vi) | **TMF678** | ✅ Invoice (VAT 10%) + **idempotent SQS consumer**; khách chỉ thấy hóa đơn của mình; doanh thu cho admin |
| `api-gateway` | Routing, auth, rate-limit | — | ✅ Spring Cloud Gateway + OAuth2 Resource Server (chặn thô; mỗi service tự kiểm JWT) |

### Tương tác giữa service

- **Sync (REST):** order → customer-service (`/customer/me`, chuyển tiếp token của khách) và order → product-catalog
  (giá do server quyết) — gọi thẳng DNS nội bộ, không qua gateway; Resilience4j bọc mọi lời gọi.
- **Async (EventBridge → SQS):** order → billing (event `OrderCompleted`).
- **Database-per-service:** mỗi service một **database + user** riêng trên cùng 1 RDS instance (Job `db-bootstrap`, B-21).
  Tách instance khi >100 QPS hoặc cần isolation cứng.

### Contract & versioning

- OpenAPI 3.1 spec trong `packages/api-contracts/`.
- URI versioning: `/tmf-api/customerManagement/v4/...`.
- Backward-compatible only — thêm trường, deprecate trước 1 release rồi mới xóa.

---

## 4. Hai chiều: Services × Environments

```
                  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐
                  │  LOCAL  │   │   DEV   │   │ STAGING │   │  PROD   │
                  │  (kind) │   │         │   │         │   │         │
                  └─────────┘   └─────────┘   └─────────┘   └─────────┘
customer-service    :local         SHA*          rc-vX         vX
product-catalog     :local         SHA*          rc-vX         vX
order-management    :local         SHA*          rc-vX         vX
billing-service     :local         SHA*          rc-vX         vX
api-gateway         :local         SHA*          rc-vX         vX
web-portal          :local         SHA*          rc-vX         vX
admin-console       :local         SHA*          rc-vX         vX
keycloak         quay.io (dev)     SHA*          rc-vX         vX
```
\* SHA = commit **cuối cùng chạm thư mục của service đó** (không phải SHA lần merge) — `rc-vX`/`vX` là tag gắn thêm
lên **cùng digest** bằng `aws ecr put-image` (ADR-005).

### Sizing per env (giá trị thật trong `environments/<env>/main.tf` + overlay)

| | Local (kind) | Dev | Staging | Prod |
|---|---|---|---|---|
| Region / AZ | máy bạn | ap-southeast-1 / 2 | ap-southeast-1 / 3 | ap-southeast-1 / 3 |
| NAT Gateway | — | 1 (+ S3 gateway endpoint — ADR-002) | 1 | 1 (module chưa có NAT HA) |
| EKS public endpoint | — | `0.0.0.0/0` | `0.0.0.0/0` **trong buổi demo** | `0.0.0.0/0` **trong buổi demo** ⚠️ |
| Node | 1 node kind | 2× t3.medium (2–3) + Karpenter Spot ≤ 8 vCPU | 3× t3.large (2–5) | 4× t3.large (3–4, vừa quota 8 vCPU) |
| RDS | Postgres StatefulSet | db.t3.micro, 20 GB, backup 1 ngày | db.t3.small, 50 GB, 7 ngày | db.t3.medium **multi-AZ**, 100 GB, 30 ngày |
| Deletion protection | — | OFF | `!ephemeral` (OFF khi demo) | `!ephemeral` (OFF khi demo) |
| Log retention / X-Ray | sink cục bộ | 3 ngày / 50% | 14 / 20% | 30 / 5% |
| Replicas/service | 1 (HPA ≤ 2) | 1 | 2 | 3 — giữ bằng HPA `minReplicas: 3` (admin-console 2, Keycloak 2) |
| Sống bao lâu | tùy | dựng theo buổi, **destroy mỗi tối** | ephemeral 1 buổi (ADR-006) | ephemeral 1 buổi (ADR-006) |
| **Chi phí khi bật** | $0 | **~$0.3–0.4/giờ** | **~$0.4/giờ** | **~$1.3/giờ** |

- ⚠️ **Endpoint `0.0.0.0/0` ở staging/prod là ngoại lệ có chủ đích**, không phải mặc định: runner GitHub không có IP cố
  định nên CIDR chặt làm CD timeout. API server vẫn cần IAM + EKS access entry; cluster chỉ sống vài giờ.
  `terraform.tfvars.example` để danh sách chặt; prod chạy thường trực thì phải chuyển sang self-hosted runner +
  endpoint private (runbook `cd-staging-prod-demo.md` §4).
- Quota On-Demand mặc định **8 vCPU/account** ⇒ chỉ chạy **một** cluster lớn tại một thời điểm (destroy dev trước khi
  dựng prod).
- Chi phí nền khi không có môi trường nào chạy: zone Route 53 **$0.50/tháng** + ECR storage. Budget alert
  `bss-platform-monthly` mặc định **$30/tháng** (`BUDGET_USD` của `bootstrap-aws.sh`).

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
| `ci-terraform.yml` | PR đụng `infrastructure/terraform/**` | fmt + validate (shared/dev/staging/prod) + Trivy IaC + plan dev (post comment) |
| `ci-k8s.yml` | PR đụng `infrastructure/kubernetes/**`, `platform/**` | kustomize build + kubeconform + kube-linter + test alert rule (promtool) |
| `publish-bss-common-java.yml` | Merge đụng `packages/bss-common-java/**` | Publish thư viện lên GitHub Packages (bump `<version>` mỗi lần đổi) |
| `ci-keycloak.yml` | PR đụng `apps/identity/keycloak/**` | docker build + Trivy + chạy thật 2 replica rootfs chỉ đọc (ADR-011) |
| `ci-scripts.yml` | PR đụng `scripts/**` | shellcheck + test `release-manifest.sh` / `smoke.sh` |
| `cd-dev.yml` | Merge `main` / thủ công | plan (desired từ git) → build service thiếu image → apply manifest 8 image (7 service + Keycloak) + smoke thật → PASS thì ghi `deploy-state`; hỏng thì rollback về manifest cũ (ADR-005) |
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

## 6. Cấu trúc thư mục (thực tế)

```
bss-platform/
├── apps/                                ← TẤT CẢ APP CHẠY ĐƯỢC (8 image)
│   ├── frontend/
│   │   ├── web-portal/                 ← Vite + React + Nginx (khách) — src/auth (PKCE), src/api/client.ts (axios + Bearer)
│   │   └── admin-console/              ← Vite + React + Nginx (nhân viên, base /admin/)
│   ├── identity/
│   │   └── keycloak/                   ← Image Keycloak optimized cho AWS (ADR-011)
│   └── backend/
│       ├── api-gateway/                ← Spring Cloud Gateway (WebFlux) + JWT chặn thô
│       ├── customer-service/           ← TMF629
│       ├── product-catalog/            ← TMF620
│       ├── order-management/           ← TMF622 (outbox → EventBridge, Idempotency-Key)
│       └── billing-service/            ← TMF678 (SQS consumer idempotent)
│
├── packages/                            ← LIBRARY DÙNG CHUNG
│   ├── bss-common-java/                ← 0.2.0 trên GitHub Packages: RFC 7807 handler, OffsetPageRequest, CurrentCaller, UUID v7
│   └── api-contracts/                  ← OpenAPI 3.1 (viết tay) + JSON Schema event OrderCompleted
│
├── infrastructure/
│   ├── terraform/
│   │   ├── modules/                    ← 9 module: vpc · eks · rds · ecr · eventbridge · iam · observability · platform-iam · waf
│   │   └── environments/
│   │       ├── shared/                 ← ECR (8 repo), GitHub OIDC + 3 role deployer, zone Route 53 + cert ACM — KHÔNG destroy
│   │       ├── dev/                    ← 2 AZ, Karpenter
│   │       ├── staging/                ← ephemeral
│   │       └── prod/                   ← ephemeral, RDS multi-AZ
│   └── kubernetes/
│       ├── base/                       ← 7 service (deployment, service, sa, hpa, pdb) + ingress + network-policies/
│       ├── components/
│       │   ├── keycloak-realm/         ← realm "bss" dùng chung mọi nơi
│       │   └── keycloak-aws/           ← Keycloak trên EKS (image riêng, PDB, NetworkPolicy)
│       └── overlays/
│           ├── local/                  ← kind: Postgres StatefulSet, LocalStack, Keycloak start-dev + user thử
│           ├── dev/ staging/ prod/     ← image ECR, ConfigMap, replicas, IRSA, secrets/ (SPC từng service)
│           └── <env>/db-bootstrap/     ← Job một lần: 5 database + 5 user trên RDS (B-21)
│
├── platform/                            ← ADDON CẤP CLUSTER (Helm values + manifest, cài bằng script)
│   ├── networking/                     ← ALB Controller, ExternalDNS, Karpenter NodePool
│   ├── storage/                        ← StorageClass gp3
│   ├── secrets/                        ← Secrets Store CSI values
│   ├── monitoring/                     ← kube-prometheus-stack, ServiceMonitor, alert (+ test), dashboard
│   ├── logging/                        ← Fluent Bit → CloudWatch
│   └── tracing/                        ← OTel Collector → X-Ray
│
├── deploy/                              ← LOCAL KHÔNG K8S: docker-compose (Postgres, Redis, LocalStack, Keycloak, Adminer)
│
├── .github/
│   ├── workflows/                      ← 10 workflow (6 CI + publish thư viện + 3 CD) — mục 5
│   └── actions/deploy-release/         ← composite action dùng chung 3 CD (render → apply → rollout → drift → smoke → rollback)
│
├── scripts/                             ← 25 script + lib/keycloak.sh (bootstrap, kind, e2e, platform-install, smoke, teardown, release-manifest…)
├── tools/ops/                           ← Python boto3: orphan_finder, cost_report, dlq_tool, health_check
├── tests/                               ← load/ (k6) · e2e-browser/ (Playwright)
│
├── docs/
│   ├── adr/                            ← 13 ADR (000 → 012)
│   ├── runbooks/                       ← 17 runbook (mỗi alert một cái + CD, auth, https-domain, WAF…)
│   ├── labs/                           ← lab có số đo thật (K8s, rollback, load test, chaos, PITR)
│   ├── architecture/                   ← ảnh kiến trúc lúc scaffold
│   ├── images/                         ← ảnh chụp 2 website
│   └── SETUP.md · ROADMAP.md · SLO.md · POSTMORTEMS.md · demo-script.md · blog-post-draft.md
│
├── CLAUDE.md · README.md · CHANGELOG.md · CONTRIBUTING.md · SECURITY.md · LICENSE
├── Makefile                             ← `make help` liệt kê mọi target
└── kind.yaml                            ← cấu hình cluster kind

(local, .gitignore) learning/ — sổ tay học tập + nhật ký · course/ — đề cương của thầy
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
- State: **react-query** cho server state; UI state dùng `useState` cục bộ. Chỉ thêm thư viện state (vd. zustand) khi
  có state thật sự dùng chung nhiều trang — dependency khai báo mà không dùng thì gỡ (2026-10-02).
- Component layout: `pages/`, `components/`, `auth/`, `api/` (axios client viết tay, tự gắn Bearer — chưa sinh từ OpenAPI).
- Tests: **vitest + @testing-library/react**.

### Kubernetes
- Mỗi service: Deployment + Service + ServiceAccount + HPA + PDB.
- **3 probes bắt buộc:** startup + liveness + readiness.
- Container chạy `runAsNonRoot: true, readOnlyRootFilesystem: true`, drop all caps.
- Image tag = git SHA (không bao giờ `latest`).
- Mọi container có cả `requests` + `limits` (Karpenter cần để chọn instance đúng).

### Terraform
- `terraform fmt && terraform validate` trước commit.
- Module hóa khi tái sử dụng (9 module trong `modules/`). Thứ sống lâu hơn môi trường → state `shared`.
- Resource cost cao (HA RDS, GPU, MSK) → cảnh báo trong PR description.
- Secret không vào `.tfvars` — sinh random → Secrets Manager.

---

## 8. Lộ trình triển khai theo Phase

> Danh sách Phase 0–10 dưới đây là **kế hoạch lúc scaffold**. Khi tiếp nhận, lộ trình được làm lại thành **Giai đoạn
> 0–9 + dọn nợ** (`learning/20-lo-trinh-hoan-thanh.md`, bằng chứng ở §13). Bảng này đối chiếu từng mục của kế hoạch
> cũ với nơi nó **đã được làm thật** — để không ai đọc các ô trống rồi tưởng dự án chưa bắt đầu.

| Phase (kế hoạch scaffold) | Trạng thái | Làm ở đâu / ghi chú |
|---|---|---|
| 0 — Chuẩn bị (account AWS, MFA, budget, toolchain) | ✅ | GĐ0 + GĐ4; toolchain trong WSL2 (`learning/19` phần 0) |
| 1 — Local development (compose, CRUD, Flyway, Testcontainers) | ✅ | GĐ1: `scripts/e2e-local.sh` PASS, đặt hàng thật qua trình duyệt |
| 2 — AWS bootstrap (S3 state, budget, backend `s3`) | ✅ | GĐ4: bucket `bss-tfstate-<account>` + `use_lockfile` (không DynamoDB) |
| 3 — Deploy infrastructure dev + addon | ✅ | GĐ4–5: `terraform apply`, `platform-install.sh` (ALB, CSI, Karpenter, ExternalDNS) |
| 4 — Deploy first service | ✅ | GĐ5: 7 service trên EKS, hóa đơn thật qua IRSA |
| 5 — CI/CD wiring | ✅ | GĐ3 (CI) + GĐ6 (CD, ADR-005, rollback thật) |
| 6 — Service nghiệp vụ TMF620/622/678 + web-portal | ✅ | GĐ1 + GĐ9 (danh tính, quyền sở hữu, 2 website thật) |
| 7 — Observability (Prometheus, Grafana, OTel, SLO, alert → chat) | ✅ | GĐ2 (kind) + GĐ7/dọn nợ (EKS): alert → Discord, SLO burn-rate, log JSON + `trace_id` → X-Ray |
| 8 — Staging + prod (tag rc → v, duyệt tay) | ✅ | GĐ6 + GĐ9: `rc-v2.2.0` → `v2.2.0` (HTTPS) — staging/prod ephemeral (ADR-006) |
| 9 — Hardening: WAF, NetworkPolicy, PSS restricted, chaos | ✅ | WAF (GĐ7), NetworkPolicy 12/12 cả 3 môi trường, PSS `restricted`, chaos xóa Pod + drain node (lab 08) |
| 9 — Hardening: **fail 1 AZ → cluster vẫn serve** | ✅ 2026-10-02 (còn 1 điểm mở) | [Lab 10](docs/labs/10-az-outage.md), 2 lần trên prod: API 0,89 % / 1,35 % lỗi (≤ 25 s), 0 Pod Pending, e2e PASS. Lộ + sửa: Keycloak mất cluster sau RDS failover (→ 26.8.0, tự ghép lại sau 34 s), HPA hạ prod về 2 replica (→ `minReplicas: 3`). Còn mở: readiness Keycloak treo ~16 phút theo timeout TCP |
| 10 — POSTMORTEMS.md | ✅ | `docs/POSTMORTEMS.md` (PM-01: test "xanh giả") |
| 10 — Video demo 5 phút | ⏳ việc của chủ repo | Kịch bản sẵn: `docs/demo-script.md` |
| 10 — Blog post | 🟡 bản nháp | `docs/blog-post-draft.md` — chưa đăng |
| 10 — Mời senior review | ⏳ việc của chủ repo | Buổi review với thầy = ô cuối của Definition of Done |

---

## 9. Quy ước cho Claude khi làm việc với repo này

### Nguyên tắc chung
- **Bám lộ trình Phase.** Không nhảy cóc nếu user chưa khẳng định.
- **Hỏi trước khi tốn tiền.** Bất kỳ `terraform apply`, `aws ... create`, `kubectl create` đụng AWS thật → confirm trước.
- **Không commit secret.** `.env`, `.tfvars`, AWS credentials → trong `.gitignore`.
- **Mọi `terraform apply` đi kèm `plan` để user duyệt.**
- Khi user mơ hồ — hỏi 1 câu làm rõ, không đoán.

### Khi tạo backend service mới
1. Copy cấu trúc từ `customer-service` hoặc `product-catalog` (đã dùng `bss-common-java`, `SecurityConfig`, UUID v7).
2. Đổi `groupId`/`artifactId` trong `pom.xml`, package `com.bss.<svc>`.
3. Tạo Flyway migration `V1__init_<svc>.sql`.
4. Tối thiểu: 1 controller, 1 service, 1 repo, 1 entity, 1 DTO, 1 integration test (+ `*AuthIT` cho luật quyền).
5. Thêm K8s base manifests vào `infrastructure/kubernetes/base/<svc>/` và `base/kustomization.yaml`;
   NetworkPolicy cho ai được gọi nó (`base/network-policies/`).
6. Database + user riêng: `bootstrap_one` + SPC + env của Job trong `overlays/<env>/db-bootstrap/`, secret trong `modules/rds`
   (`service_databases`) + SecretProviderClass `overlays/<env>/secrets/`.
7. IRSA role trong `infrastructure/terraform/environments/*/main.tf` (mục `services`).
8. Repo ECR: `modules/ecr/variables.tf` (apply ở `shared`); CD: thêm vào `SERVICES` trong `scripts/release-manifest.sh`
   (desired/manifest/rollback tính theo danh sách này); CI: filter + danh sách service trong `ci-backend.yml`.

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

> ✅ = đang đúng trong hệ thống; ⚠️ = ngoại lệ có chủ đích (ghi lý do + nơi ghi quyết định).

### Security
- ✅ Không có AWS access key trong repo/CI — Pod dùng IRSA, CI dùng GitHub OIDC (role theo GitHub Environment).
  Máy cá nhân dùng IAM user có MFA để chạy Terraform.
- ✅ Không có secret cleartext trong manifest hay env var (Secrets Manager + CSI); webhook Discord chỉ nằm trong Secret.
- ✅ Không log PII, password, OTP, token, CCCD.
- ✅ Mọi image (kể cả Keycloak) qua Trivy trong CI; fail nếu HIGH/CRITICAL chưa fix. `.trivyignore` phải ghi lý do.
- ✅ Pod chạy non-root, readOnly root FS, drop all caps; namespace `bss` enforce PSS `restricted`.
- ✅ NetworkPolicy default-deny + whitelist từng cặp — đo bằng `scripts/netpol-matrix.sh` (12/12 cả 3 môi trường).
- ✅ Mỗi service một IAM role + một DB user; `/auth/admin` của Keycloak không ra internet.
- ✅ ECR repo `IMMUTABLE` tags.
- ⚠️ EKS public endpoint **restricted** ở prod — chỉ đúng khi prod chạy thường trực. Trong buổi demo ephemeral đang dùng
  `0.0.0.0/0` vì runner GitHub không có IP cố định (`docs/runbooks/cd-staging-prod-demo.md` §4).

### Reliability
- ✅ ≥2 replica ở staging/prod, PDB `minAvailable` ≥ 1 (dev 1 replica dùng `maxUnavailable: 1` để Karpenter gom node được).
- ✅ HPA theo **CPU** (bỏ memory — JVM giữ heap nên HPA memory không bao giờ scale down, #203). Custom metric req/s: chưa làm.
- ✅ Gọi REST giữa service: timeout + retry + circuit breaker (Resilience4j); DB: HikariCP pool tối đa 5/Pod (ngân sách kết nối RDS).
- ✅ Probe có timeout thật (liveness 5 s, readiness 3 s) — timeout mặc định 1 s từng làm kubelet giết Pod dưới tải.
- ✅ SLI/SLO + error budget burn-rate alert (`docs/SLO.md`, `order-management`).
- ⚠️ Mất 1 AZ + RDS failover đã đo 2 lần (Lab 10): service Spring sống (≤ 25 s lỗi), cluster Keycloak tự hồi phục từ 26.8.0;
  còn mở: readiness Keycloak treo ~16 phút (timeout TCP kernel); 1 NAT là SPOF.

### Cost
- ✅ Dev: `make ENV=dev tf-destroy` mỗi tối; staging/prod ephemeral (ADR-006). Sau destroy chạy `tools/ops/orphan_finder.py`.
- ✅ Dev: db.t3.micro, t3.medium, không HA; Karpenter chọn Spot (trần 8 vCPU).
- ✅ Mạng dev: **1 NAT + S3 gateway endpoint** (ADR-002). Quy tắc cũ "VPC Endpoint thay NAT" sai ở quy mô 2 AZ: thiếu
  endpoint thì cluster không chạy được, đủ endpoint thì đắt hơn NAT.
- ✅ ECR lifecycle policy auto-xóa image cũ.
- ✅ Budget alert `$30/tháng` (mục tiêu < $50/tháng); `tools/ops/cost_report.py` xem chi phí 7 ngày theo dịch vụ.

### Operability
- ✅ Mọi service expose `/actuator/health`, `/actuator/prometheus` (ServiceMonitor theo nhãn `tier: backend`).
- ✅ Dashboard Grafana `bss-overview` (RED + saturation) lọc theo biến `$application` — một dashboard cho mọi service.
- ✅ Mọi alert có `runbook_url` annotation (`docs/runbooks/`), tới Discord qua Alertmanager.
- ✅ Log JSON có `trace_id` correlate với X-Ray.

---

## 11. Lệnh thường dùng (cheatsheet)

```bash
make help                                    # liệt kê mọi target

# Bootstrap (1 lần per account) — rồi `make ENV=shared tf-init tf-plan tf-apply` (ECR, OIDC, role, zone, cert)
make bootstrap                               # S3 tfstate (use_lockfile) + budget + Spot service-linked role

# Local, $0
./scripts/e2e-local.sh                       # docker-compose + 5 service + Keycloak → luồng đầy đủ → PASS
./scripts/kind-up.sh && ./scripts/auth-install.sh kind && make kind-load deploy-local
make ENV=kind e2e e2e-browser                # e2e-flow.sh + Playwright trên http://bss.localhost

# Infrastructure (ENV=dev|staging|prod) — LUÔN qua make (truyền -backend-config, B-38)
make ENV=dev tf-init
make ENV=dev tf-plan                         # đọc kỹ trước khi apply
make ENV=dev tf-apply                        # cần confirm!
make ENV=dev kube-config
./scripts/platform-install.sh dev            # ALB Controller, gp3, Secrets CSI, Karpenter (dev), ExternalDNS
kubectl apply -k infrastructure/kubernetes/overlays/dev/db-bootstrap   # 5 DB + 5 user (rồi delete Job)

# Deploy = GitHub Actions "CD — dev" (merge main hoặc Run workflow) — không kubectl apply tay
./scripts/smoke.sh dev                       # 7 kiểm qua https://dev.bssplatform.dpdns.org
make ENV=dev e2e e2e-browser                 # 2 website, khách + nhân viên
make ENV=dev admin-user USERNAME=<u> EMAIL=<e>   # tài khoản nhân viên (mật khẩu tạm)

# Promote — v* phải trỏ CÙNG commit với rc-v* đã qua staging
git tag rc-v2.3.0 <commit> && git push origin rc-v2.3.0   # → cd-staging
git tag v2.3.0    <commit> && git push origin v2.3.0      # → cd-prod (duyệt tay)

# Kết thúc buổi
make ENV=dev tf-destroy                      # teardown.sh: Ingress → chờ DNS → NodePool → ENI/SG sót → destroy
python tools/ops/orphan_finder.py            # phải rỗng
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
- **Phase hiện tại: 9 hoàn thành + dọn nợ xong; release mới nhất `v2.2.0` (HTTPS, chạy thật trên dev/staging/prod).** Mọi phase đã **hoàn thành và kiểm chứng thật** trên hạ tầng thật
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
| 2 website trên mọi môi trường (2026-10-02) | ✅ | `e2e-flow.sh` (khách + nhân viên + khách khác, kiểm cả phía admin) PASS + Playwright 3/3 trên kind, dev, staging, prod; chủ repo cấp tài khoản nhân viên bằng `admin-user.sh` rồi tự duyệt khách + đối chiếu hóa đơn 2 phía trên dev/staging/prod |

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
- ~~Tỉ lệ lỗi 7,9% dưới tải 700 req/s có Karpenter~~ — ✅ 2026-10-01 (#203): 2 nguyên nhân có bằng chứng — probe
  timeout mặc định 1 s (kubelet giết gateway → 502) và hết kết nối RDS (→ 500); probe 5 s/3 s + HikariCP max 5 → **0% lỗi**,
  3 lần đo liền (`docs/labs/07-load-test-dev.md` §2c).
- ~~B-15~~ — ✅ code xong 2026-10-01 (PR bss-common-java 0.2.0 + PR các service): UUID v7, `Idempotency-Key` cho
  `productOrder`, merge-patch `null` = xóa, 4 service dùng `bss-common-java` (#199, #200 đã merge).
- **0 issue mở** (2026-10-02). Ngoài repo: buổi review với thầy (ô cuối của Definition of Done — việc của chủ repo).

# 00 — Tổng quan dự án: BSS Platform là gì, chạy thế nào, mỗi file để làm gì

> Mục tiêu bài: sau 2–3 giờ, bạn **kể lại được** hệ thống cho người khác trong 5 phút, và khi nhìn
> bất kỳ file nào trong repo, bạn biết nó thuộc lớp nào, ai dùng nó, khi nào cần đụng vào.

---

## Tóm tắt 1 trang (đọc lại mỗi khi quay về dự án)

- **BSS (Business Support System)** = phần mềm "phía kinh doanh" của nhà mạng: quản lý **khách hàng**, **danh mục gói cước**, **đơn hàng đăng ký**, **hóa đơn**. (Phía "mạng" — kích hoạt SIM, định tuyến — là **OSS**, không nằm trong dự án.)
- API theo chuẩn **TM Forum Open API**: TMF629 (Customer), TMF620 (Product Catalog), TMF622 (Product Ordering), TMF678 (Customer Bill).
- **7 thành phần chạy được**: 4 microservice Java/Spring Boot + 1 API Gateway (Spring Cloud Gateway) + 2 frontend React (web-portal cho khách, admin-console cho nhân viên).
- **Dữ liệu**: PostgreSQL (mỗi service một database). **Sự kiện** order → billing đi qua **EventBridge → SQS** (bất đồng bộ), dùng 2 pattern quan trọng: **Transactional Outbox** và **Idempotent Consumer**.
- **Hạ tầng**: AWS (VPC, EKS, RDS, ECR, EventBridge, SQS, Secrets Manager, CloudWatch, X-Ray) viết bằng **Terraform**; manifest Kubernetes viết bằng **Kustomize** cho 3 môi trường dev/staging/prod.
- **CI/CD**: GitHub Actions, xác thực AWS bằng **OIDC** (không có access key), promotion bằng **git tag** (`rc-v*` → staging, `v*` → prod có duyệt tay).
- **Hiện trạng thật** (chi tiết ở [01](01-hien-trang-va-danh-sach-loi.md)): code và cấu hình **đã được viết rộng khắp** nhưng **chưa từng chạy end-to-end**. Terraform hiện còn không `init` được. Nhiệm vụ của bạn là **biến bản thiết kế thành hệ thống chạy thật** — đây chính là phần giá trị nhất để học.

---

## 1. BSS là gì — hiểu bài toán trước khi hiểu code

### 1.1 BSS vs OSS

| | BSS — Business Support System | OSS — Operations Support System |
|---|---|---|
| Hướng về | Khách hàng, tiền, sản phẩm | Mạng lưới, thiết bị |
| Ví dụ | Đăng ký gói "Pro 80", xuất hóa đơn tháng, đổi thông tin thuê bao | Kích hoạt SIM trên HLR/HSS, cấp băng thông, giám sát trạm BTS |
| Ở Viettel/VNPT | CRM, Billing, Product Catalog | Hệ thống điều hành mạng, NOC |

Dự án này **chỉ làm BSS**. Khi đơn hàng "hoàn tất", một BSS thật sẽ gửi yêu cầu sang OSS để kích hoạt dịch vụ — ở đây được **giản lược**: đơn hàng tự chuyển `Completed` ngay ([OrderService.java:56-58](../apps/backend/order-management/src/main/java/com/bss/order/service/OrderService.java)).

### 1.2 TM Forum Open API là gì và vì sao quan trọng

TM Forum là hiệp hội ngành viễn thông, định nghĩa **~70 API chuẩn** để các nhà mạng/đối tác tích hợp với nhau mà không phải thiết kế lại mỗi lần. Chuẩn quy định đường dẫn (`/tmf-api/customerManagement/v4/customer`), tên trường (`lifecycleStatus`, `validFor`...), trạng thái (`Acknowledged → InProgress → Completed`).

| API | Service trong repo | Tài nguyên chính |
|---|---|---|
| TMF629 Customer Management | `customer-service` | `Customer` |
| TMF620 Product Catalog | `product-catalog` | `Category`, `ProductSpecification`, `ProductOffering` |
| TMF622 Product Ordering | `order-management` | `ProductOrder`, `OrderItem` |
| TMF678 Customer Bill | `billing-service` | `BillingAccount`, `CustomerBill` (Invoice) |

⚖️ Repo chỉ implement **một tập con** của mỗi chuẩn (đủ cho demo). Khi phỏng vấn, nói "aligned with TMF (subset)" chứ đừng nói "TMF compliant".

🔁 **Nối với đồ án của bạn**: đồ án OSM có `user/product/order/payment` — gần như ánh xạ 1-1 sang `customer/product-catalog/order-management/billing`. Khác biệt lớn: ở đồ án, `order-service` gọi **đồng bộ** HTTP sang service khác; ở đây `order → billing` là **bất đồng bộ qua hàng đợi** — chính là hướng "SQS/RabbitMQ" bạn đề xuất ở slide 10c (mức ~1.000.000 users).

---

## 2. Một request đi xuyên hệ thống — câu chuyện "khách đăng ký gói Pro 80"

Đây là cách nhanh nhất để hiểu **tất cả** thành phần. Đọc chậm, đối chiếu với sơ đồ (GitHub và VS Code có extension Mermaid sẽ vẽ được).

```mermaid
sequenceDiagram
    autonumber
    participant B as Trình duyệt
    participant ALB as AWS ALB (Ingress)
    participant WP as web-portal (Nginx)
    participant GW as api-gateway
    participant PC as product-catalog
    participant OM as order-management
    participant DB as PostgreSQL
    participant EB as EventBridge
    participant Q as SQS billing-orders
    participant BS as billing-service

    B->>ALB: GET https://dev.bss.example.com/plans
    ALB->>WP: path "/" → Service web-portal:80
    WP-->>B: index.html + JS bundle (React SPA)
    B->>ALB: GET /api/tmf-api/productCatalog/v4/productOffering
    ALB->>GW: path "/api" → Service api-gateway:80
    GW->>PC: StripPrefix=1 → /tmf-api/productCatalog/v4/productOffering
    PC->>DB: SELECT ... FROM product_offering
    PC-->>B: 200 [Lite 30, Pro 80, ...] + X-Total-Count
    B->>GW: POST /api/tmf-api/orderManagement/v4/productOrder
    GW->>OM: /tmf-api/orderManagement/v4/productOrder
    OM->>DB: BEGIN; INSERT product_order, order_item, event_outbox; COMMIT
    OM-->>B: 201 Created (state=Completed)
    loop mỗi 2 giây (OrderEventPublisher)
        OM->>DB: SELECT outbox WHERE published_at IS NULL
        OM->>EB: PutEvents(OrderCompleted)
        OM->>DB: UPDATE outbox SET published_at=now()
    end
    EB->>Q: rule source=bss.order, detail-type=OrderCompleted
    loop mỗi 5 giây (OrderEventListener, long-poll 10s)
        BS->>Q: ReceiveMessage
        BS->>DB: INSERT processed_event (chống trùng) + INSERT invoice (+VAT 10%)
        BS->>Q: DeleteMessage (ACK)
    end
    B->>GW: GET /api/tmf-api/billingManagement/v4/customerBill?customerId=... (poll 5s)
    GW->>BS: → danh sách hóa đơn
```

Diễn giải (số tương ứng sơ đồ):

- **1–3.** Người dùng mở trang. ALB (do **AWS Load Balancer Controller** tạo từ [ingress.yaml](../infrastructure/kubernetes/base/ingress.yaml)) nhận request, path `/` → Service `web-portal` → Pod chạy **Nginx** phục vụ file tĩnh React đã build. 🔁 Đồ án bạn dùng **NGINX Ingress Controller + NLB**; ở đây **ALB Controller** biến chính resource `Ingress` thành một ALB thật của AWS.
- **4–5.** Code React ([PlansPage.tsx](../apps/frontend/web-portal/src/pages/PlansPage.tsx)) gọi `/api/...`. ALB thấy prefix `/api` → chuyển tới `api-gateway`.
- **6.** Gateway ([application.yml](../apps/backend/api-gateway/src/main/resources/application.yml)) so khớp route theo path, **bỏ đoạn `/api`** (StripPrefix=1) rồi gọi DNS nội bộ `http://product-catalog.bss.svc.cluster.local`.
- **7–8.** `product-catalog` truy vấn Postgres (schema do **Flyway** tạo, có sẵn 4 gói mẫu), trả JSON + header `X-Total-Count` (tổng số bản ghi cho phân trang).
- **9–12.** Người dùng bấm "Xác nhận đăng ký". `order-management` ghi **đơn hàng và một dòng "sự kiện chờ gửi"** (`event_outbox`) trong **cùng một transaction** → hoặc cả hai được lưu, hoặc không cái nào.
- **13–15.** Một job định kỳ (`@Scheduled`) đọc outbox, gửi sự kiện `OrderCompleted` lên **EventBridge**, rồi đánh dấu đã gửi. Đây là **Transactional Outbox pattern** — học sâu ở [bài 10](10-backend-java-spring.md).
- **16.** **EventBridge rule** lọc sự kiện theo `source` + `detail-type` và đẩy vào hàng đợi **SQS** riêng của billing (có **DLQ** — hàng đợi "thư chết" cho message xử lý lỗi quá 5 lần).
- **17–19.** `billing-service` long-poll SQS, ghi `processed_event` để **chống xử lý trùng** (SQS đảm bảo *at-least-once* — một message có thể đến hơn một lần), tạo hóa đơn có VAT 10%, rồi xóa message (ACK).
- **20.** Trang "Hóa đơn" **tự poll mỗi 5 giây** vì hóa đơn xuất hiện *sau* đơn hàng vài giây (**eventual consistency** — nhất quán sau cùng).

❓ Tự kiểm tra: *Nếu EventBridge sập đúng lúc khách đặt hàng thì chuyện gì xảy ra với đơn hàng? Với hóa đơn?*

<details><summary>Đáp án</summary>

Đơn hàng vẫn lưu thành công (khách không thấy lỗi) vì bước 12 chỉ ghi DB. Dòng outbox nằm ở trạng thái chưa gửi; job ở bước 13 thử lại mỗi 2 giây cho đến khi EventBridge sống lại → hóa đơn được tạo trễ nhưng không mất. Đây chính là lý do tồn tại của outbox.

</details>

---

## 3. Kiến trúc 5 lớp + Platform — lớp nào đã có code thật

```
LỚP 1  Người dùng (web/mobile/B2B)
LỚP 2  Edge: CloudFront → AWS WAF → ALB        ← chỉ ALB có trong code (qua Ingress). CloudFront/WAF: chưa có dòng code nào
LỚP 3  Frontend (EKS): web-portal, admin-console  ← có code, Dockerfile, manifest
LỚP 4  Backend (EKS): api-gateway + 4 service     ← có code + test; Dockerfile đang lỗi (B-01)
LỚP 5  Data: RDS PostgreSQL, EventBridge + SQS, S3, Redis
                                                  ← RDS/EventBridge/SQS có Terraform; S3 cho app & Redis: chưa dùng
PLATFORM: VPC, EKS, IAM/IRSA, Secrets Manager, Prometheus/Grafana, Fluent Bit→CloudWatch,
          OTel→X-Ray, ALB Controller, ExternalDNS, Karpenter, GitHub OIDC
                                                  ← có Terraform + Helm values, nhưng thiếu IAM cho addon (B-35)
```

Hình minh họa thầy đã vẽ: [bss_eks_architecture.png](../docs/architecture/bss_eks_architecture.png) và trang tương tác [interactive_architecture.html](../docs/architecture/interactive_architecture.html) (mở bằng trình duyệt).

⚖️ Bảng "vì sao chọn" nằm ở [CLAUDE.md mục 2](../CLAUDE.md). Khi đọc bảng đó, luôn tự hỏi thêm "**đổi lại mất gì?**" — ví dụ Karpenter rẻ hơn nhờ spot nhưng thêm một controller phải vận hành và cần IAM riêng.

---

## 4. Bản đồ thư mục — MỌI file trong repo để làm gì

> Cột "Đụng khi": **D** = hằng ngày khi viết tính năng · **H** = khi đổi hạ tầng · **1L** = một lần/hiếm · **R** = chỉ đọc.

### 4.1 Gốc repo

| File | Vai trò | Đụng khi |
|---|---|---|
| [CLAUDE.md](../CLAUDE.md) | "Hiến pháp" của dự án cho Claude Code: kiến trúc, quy ước code, lộ trình Phase 0–10. ⚠️ Mục 13 "trạng thái" **lạc quan hơn thực tế** | R, cập nhật khi chuyển phase |
| [README.md](../README.md) | Trang giới thiệu public. Badge CI đang trỏ repo `gemmy94/bss-platform` (repo gốc của thầy) | 1L |
| [Makefile](../Makefile) | Phím tắt: `make local-up`, `make ENV=dev tf-apply`... ⚠️ Windows không có `make` sẵn | D |
| [CHANGELOG.md](../CHANGELOG.md) | Lịch sử phiên bản theo *Keep a Changelog* + *SemVer* | khi release |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Quy ước commit (*Conventional Commits*), style, checklist PR | R |
| [SECURITY.md](../SECURITY.md) | Cách báo lỗ hổng bảo mật | R |
| [LICENSE](../LICENSE) | MIT — ai cũng được dùng, miễn giữ ghi công | R |
| [.gitignore](../.gitignore) | Không commit secret (`.env`, `*.tfvars`, `*.pem`), build output, state Terraform. Dòng cuối ignore `course/` | 1L |
| `.vscode/settings.json` | Cấu hình Java cho VS Code | R |
| `.DS_Store` (nhiều nơi) | Rác của macOS (máy thầy), không được track — xóa thoải mái | — |

### 4.2 `apps/` — mọi thứ **chạy được**

**Backend** (`apps/backend/<service>/`) — mỗi service là một project Maven độc lập, cấu trúc giống nhau:

| Đường dẫn trong service | Vai trò |
|---|---|
| `pom.xml` | Khai báo dependency + plugin build (🔁 như `package.json`) |
| `Dockerfile` | Đóng gói thành image (⚠️ B-01) |
| `src/main/java/com/bss/<svc>/<Svc>Application.java` | Hàm `main`, khởi động Spring Boot |
| `.../controller/` | Nhận HTTP request (🔁 như `router.get()` trong Express) |
| `.../service/` | Nghiệp vụ + `@Transactional` |
| `.../repository/` | Truy cập DB (Spring Data JPA) |
| `.../model/` | Entity ánh xạ bảng DB (🔁 như Mongoose model) |
| `.../dto/` | Dữ liệu vào/ra API (Java `record`) |
| `.../exception/` | Chuyển exception thành lỗi HTTP chuẩn RFC 7807 |
| `.../config/AwsConfig.java` | Tạo AWS SDK client (chỉ order + billing) |
| `src/main/resources/application.yml` | Cấu hình (DB, port, actuator...) |
| `src/main/resources/db/migration/V1__*.sql` | Flyway migration — **schema DB thuộc về file này** |
| `src/test/java/.../*IT.java` | Integration test chạy Postgres thật bằng Testcontainers |
| `target/` (chỉ có trên máy) | Output build cũ của thầy (`.class`), bị ignore |

| Service | File đặc thù đáng chú ý |
|---|---|
| `customer-service` | `dto/PatchCustomerRequest.java` (PATCH từng phần); entity dùng thẳng làm body API |
| `product-catalog` | 2 controller (`Category`, `ProductOffering`), `LifecycleStatus.java`, seed 4 gói trong `V1__init_product.sql` |
| `order-management` | `event/OrderEventPublisher.java` (outbox drainer), `model/EventOutbox.java` (cột JSONB) |
| `billing-service` | `listener/OrderEventListener.java` (SQS consumer), `model/ProcessedEvent.java` (bảng chống trùng) |
| `api-gateway` | Chỉ 1 class `main` + `application.yml` chứa toàn bộ route |

**Frontend** (`apps/frontend/<app>/`):

| File | Vai trò |
|---|---|
| `package.json` | Dependency + script `dev/build/lint/test` |
| `vite.config.ts` | Dev server (port 3000 / 3001) + **proxy `/api` → localhost:8080** |
| `tsconfig.json` | TypeScript strict |
| `index.html`, `src/main.tsx` | Điểm vào; gắn React Query + Router |
| `src/App.tsx` | Khai báo các route trang |
| `src/api/client.ts` | axios với `baseURL` là `/api` |
| `src/pages/*.tsx` | web-portal: Home, Plans, Order, Bills — admin-console: Dashboard, Customers, Offerings |
| `nginx.conf` | Nginx phục vụ SPA (fallback `index.html`), cache asset, `/healthz` |
| `Dockerfile` | Build Node 20 → chạy Nginx non-root port 8080 (⚠️ B-05) |

### 4.3 `packages/` — thư viện dùng chung

| Đường dẫn | Vai trò | Thực tế |
|---|---|---|
| `bss-common-java/` | `PageResponse`, `NotFoundException`, `GlobalExceptionHandler` dùng chung | **Chưa service nào dùng** — mỗi service tự chép một bản |
| `ui-kit/` | Component React `Button`, `Card` | **Chưa frontend nào dùng** |
| `api-contracts/*.yaml` | OpenAPI 3.1 của 4 service — "hợp đồng" API | Viết tay, chưa sinh code/kiểm tra tự động |
| `api-contracts/events/OrderCompleted.schema.json` | JSON Schema cho payload sự kiện | Khớp với payload trong `OrderService` |

### 4.4 `infrastructure/` — hạ tầng dạng code

```
infrastructure/
├── terraform/
│   ├── modules/                 ← "hàm" tái sử dụng (🔁 như 5 module đồ án của bạn)
│   │   ├── vpc/                 VPC 2–3 AZ, subnet public/private, NAT tùy chọn, VPC Endpoints
│   │   ├── eks/                 EKS cluster + node group "system" + OIDC provider (IRSA) + addons
│   │   ├── rds/                 PostgreSQL + mật khẩu random lưu Secrets Manager
│   │   ├── ecr/                 7 repo image, IMMUTABLE tag, lifecycle policy
│   │   ├── eventbridge/         Event bus + SQS + DLQ + rule + alarm
│   │   ├── iam/                 IRSA role cho từng service + GitHub OIDC deployer
│   │   └── observability/       CloudWatch log groups + X-Ray sampling
│   └── environments/            ← "gọi hàm" với tham số từng môi trường
│       ├── dev/      main.tf, variables.tf, outputs.tf, terraform.tfvars.example
│       ├── staging/  (giống dev, lớn hơn, có NAT)
│       └── prod/     (3 AZ, RDS multi-AZ, deletion protection)
└── kubernetes/
    ├── base/                    ← manifest gốc, không phụ thuộc môi trường
    │   ├── kustomization.yaml   gom 7 service + namespace + ingress
    │   ├── namespace.yaml       namespace "bss"
    │   ├── ingress.yaml         1 ALB cho cả hệ thống: /api, /admin, /
    │   └── <service>/           deployment, service, serviceaccount, hpa, pdb, kustomization
    └── overlays/                ← "vá" theo môi trường
        ├── dev/kustomization.yaml       image, ConfigMap, replicas=1, IRSA annotation, host
        ├── staging/kustomization.yaml   replicas=2, LOG_LEVEL=INFO
        └── prod/kustomization.yaml      replicas=3, PDB minAvailable=2, request CPU/RAM cao hơn
```

### 4.5 `platform/` — addon cấp cluster (cài bằng Helm, một lần mỗi cluster)

| File | Addon | Vai trò |
|---|---|---|
| `networking/aws-load-balancer-controller-values.yaml` | AWS LB Controller | Biến `Ingress` thành ALB |
| `networking/external-dns-values.yaml` | ExternalDNS | Tự tạo bản ghi Route 53 theo host của Ingress |
| `networking/karpenter-nodepool.yaml` | Karpenter | Tự tạo node EC2 (ưu tiên spot) khi Pod Pending |
| `secrets/secrets-store-csi-values.yaml` + `customer-secrets-spc.yaml` | Secrets Store CSI + AWS provider | Mount secret từ Secrets Manager vào Pod |
| `logging/fluent-bit-values.yaml` | Fluent Bit | Gom log container → CloudWatch Logs |
| `tracing/otel-collector-values.yaml` | OpenTelemetry Collector | Nhận trace (OTLP) → AWS X-Ray |
| `monitoring/prometheus/values.yaml` | kube-prometheus-stack | Prometheus + Grafana + Alertmanager + exporters |
| `monitoring/alerts/bss-alerts.yaml` | PrometheusRule | 5 cảnh báo: down, latency, 5xx, crashloop, heap |
| `monitoring/grafana/dashboards/bss-overview.json` | Dashboard | 8 panel RED + JVM + CPU |
| `README.md` | Thứ tự cài 7 addon | ⚠️ vài lệnh sai (B-35, B-42) |

### 4.6 `deploy/` — môi trường local (không cần AWS)

| File | Vai trò |
|---|---|
| `docker-compose.yml` | Postgres 15 + Redis 7 + LocalStack 3.4 (giả lập AWS) + Adminer (UI xem DB, port 8081) |
| `postgres-init/01-create-databases.sh` | Tạo 4 database `customer`, `product`, `orders`, `billing` khi Postgres khởi động lần đầu |
| `localstack-init/01-bootstrap.sh` | Tạo trong LocalStack: event bus, SQS + DLQ, rule, target, secret |
| `.env.example` | Biến môi trường mẫu khi chạy service ngoài Docker |
| `README.md` | Hướng dẫn chạy + dùng `awslocal` |

### 4.7 `.github/` — CI/CD và mẫu cộng tác

| File | Kích hoạt | Làm gì |
|---|---|---|
| `workflows/ci-backend.yml` | PR đụng `apps/backend/**` | Maven verify + docker build + Trivy (chỉ service thay đổi) |
| `workflows/ci-frontend.yml` | PR đụng `apps/frontend/**` | npm install/lint/test/build + docker build + Trivy |
| `workflows/ci-terraform.yml` | PR đụng `infrastructure/terraform/**` | fmt + tfsec + plan dev → comment vào PR |
| `workflows/ci-k8s.yml` | PR đụng manifest | kustomize build 3 overlay + kubeconform |
| `workflows/cd-dev.yml` | push `main` đụng `apps/**` | build + push ECR (tag = SHA) + apply overlay dev |
| `workflows/cd-staging.yml` | tag `rc-v*` | re-tag image → apply staging |
| `workflows/cd-prod.yml` | tag `vX.Y.Z` | chờ duyệt tay → re-tag → apply prod → rollback nếu fail |
| `ISSUE_TEMPLATE/*.yml`, `PULL_REQUEST_TEMPLATE.md` | Khi tạo issue/PR | Form chuẩn hóa |

### 4.8 `scripts/`, `docs/`, `course/`

| Đường dẫn | Vai trò |
|---|---|
| `scripts/bootstrap-aws.sh` | Một lần/account: S3 bucket chứa tfstate, DynamoDB lock, Budget alert |
| `scripts/teardown.sh` | `terraform destroy` một môi trường (hỏi xác nhận nếu prod) |
| `scripts/smoke.sh` | Gọi thử ALB sau deploy (⚠️ B-52: không bao giờ báo fail) |
| `docs/SETUP.md` | Hướng dẫn từ account AWS mới đến deploy service đầu tiên |
| `docs/ROADMAP.md` | ⚠️ **Bản cũ từ thời dự án chạy trên GCP/GKE** — bỏ qua, dùng [20](20-lo-trinh-hoan-thanh.md) |
| `docs/architecture/*` | Tài liệu kiến trúc tiếng Việt, ảnh sơ đồ, trang HTML tương tác |
| `docs/adr`, `api`, `onboarding`, `runbooks` | **Thư mục rỗng** — chỗ để bạn viết ADR, runbook trong quá trình làm |
| `course/` | Đề cương khóa học 15 module của thầy (không được git track) |
| `learning/` | Sổ tay này |

---

## 5. Hai chiều: service × môi trường

| | DEV | STAGING | PROD |
|---|---|---|---|
| Tag image | git SHA | `rc-vX.Y.Z` | `vX.Y.Z` |
| Kích hoạt | merge vào `main` | `git tag rc-v…` | `git tag v…` + duyệt tay |
| Replicas | 1 (⚠️ HPA ép lên 2 — B-22) | 2 | 3 |
| AZ | 2 | 3 | 3 |
| NAT | không (dùng VPC Endpoint — ⚠️ B-32) | 1 | 1 (ghi "HA" nhưng chỉ tạo 1) |
| RDS | t3.micro | t3.small | t3.medium multi-AZ |
| Log retention | 3 ngày | 14 | 30 |
| X-Ray sampling | 50% | 20% | 5% |

🔁 Đồ án của bạn tách môi trường bằng **nhánh git** (`main`/`dev`) và **namespace** (`osm`/`osm-dev`) trong **một** cluster. Dự án này tách bằng **tag** và **cluster riêng cho mỗi môi trường**. ⚖️ Cluster riêng an toàn hơn (sự cố dev không ảnh hưởng prod) nhưng **đắt gấp ~3 lần** — với ngân sách sinh viên, lộ trình ở [20](20-lo-trinh-hoan-thanh.md) sẽ đề xuất cách tiết kiệm.

---

## 6. Từ điển thuật ngữ (tra nhanh)

| Thuật ngữ | Giải thích ngắn |
|---|---|
| **ALB / NLB** | Application LB (tầng 7, hiểu HTTP path/host) / Network LB (tầng 4, TCP) |
| **At-least-once** | Hàng đợi đảm bảo mỗi message đến *ít nhất* 1 lần → có thể trùng → consumer phải idempotent |
| **Actuator** | Module Spring Boot cung cấp `/actuator/health`, `/actuator/prometheus`... |
| **Bounded context** | Ranh giới nghiệp vụ của một service (DDD) |
| **DLQ** | Dead-Letter Queue — nơi chứa message xử lý lỗi quá số lần cho phép |
| **DTO** | Data Transfer Object — kiểu dữ liệu vào/ra API, tách khỏi entity DB |
| **Entity (JPA)** | Class Java ánh xạ 1 bảng DB |
| **EventBridge** | "Bộ định tuyến sự kiện" của AWS: nhận event, lọc bằng rule, đẩy tới target |
| **Eventual consistency** | Dữ liệu giữa các service nhất quán *sau một khoảng trễ*, không tức thì |
| **Flyway** | Công cụ quản lý phiên bản schema DB bằng file SQL đánh số |
| **HPA / PDB** | Horizontal Pod Autoscaler (tự scale số pod) / PodDisruptionBudget (giới hạn số pod bị tắt cùng lúc khi bảo trì) |
| **Idempotent** | Làm 1 lần hay N lần cho cùng kết quả |
| **IRSA** | IAM Roles for Service Accounts — Pod nhận quyền AWS qua ServiceAccount, không cần access key |
| **Karpenter** | Autoscaler node thế hệ mới của AWS (thay Cluster Autoscaler) |
| **Kustomize** | Công cụ "vá" YAML theo môi trường, không dùng template |
| **LocalStack** | Giả lập dịch vụ AWS trên máy local |
| **OIDC** | Chuẩn định danh; GitHub/EKS phát token, AWS STS tin token đó để cấp quyền tạm |
| **Outbox pattern** | Ghi sự kiện vào bảng trong cùng transaction với dữ liệu, gửi đi sau |
| **Probe (startup/liveness/readiness)** | Kubelet kiểm tra container đã khởi động / còn sống / sẵn sàng nhận traffic |
| **ProblemDetail (RFC 7807)** | Chuẩn JSON cho lỗi HTTP: `type, title, status, detail` |
| **ServiceMonitor** | CRD của Prometheus Operator khai báo "hãy scrape Service này" |
| **SQS long polling** | Chờ tối đa N giây để có message, giảm số lần gọi rỗng |
| **Testcontainers** | Thư viện chạy container thật (Postgres…) trong test |
| **Trivy** | Công cụ quét lỗ hổng image/IaC |
| **VPC Endpoint** | Kết nối riêng từ VPC tới dịch vụ AWS không qua Internet (Gateway: S3/DynamoDB miễn phí; Interface: tính tiền theo giờ × AZ) |

---

## 7. So sánh 30 giây với đồ án OSM của bạn

| | Đồ án OSM | BSS Platform |
|---|---|---|
| Ngôn ngữ backend | Node.js + Express | Java 21 + Spring Boot 3.2 |
| Frontend | Vue 3 + Vite | React 18 + Vite |
| DB | MongoDB trên EC2 | PostgreSQL (RDS), schema bằng Flyway |
| Giao tiếp service | HTTP đồng bộ | HTTP qua gateway + **sự kiện bất đồng bộ** |
| Cấu hình server | **Ansible** | Không cần (EKS managed node, image bất biến) |
| CI/CD | **Jenkins** trên EC2 (12 stage) | **GitHub Actions** + OIDC |
| Entry | NGINX Ingress + NLB | ALB Controller + ALB |
| Secret | K8s Secret | Secrets Manager + CSI Driver |
| Monitoring | Prometheus annotations | Prometheus Operator (ServiceMonitor) + Fluent Bit + X-Ray |
| Tự động hóa vận hành | Python boto3 scripts | Chưa có — đề xuất bổ sung |

Chi tiết từng dòng và "vì sao đổi" ở [02-cau-noi-kien-thuc.md](02-cau-noi-kien-thuc.md).

---

## 8. Checkpoint bài 00

- [ ] Kể lại được câu chuyện 20 bước ở mục 2 mà không nhìn.
- [ ] Chỉ ra được file nào quyết định: route gateway, hostname Ingress, số replica prod, kích thước RDS dev.
- [ ] Giải thích được vì sao order → billing dùng hàng đợi thay vì gọi HTTP trực tiếp (ít nhất 2 lý do).
- [ ] Viết 5 dòng Feynman vào [nhật ký](nhat-ky-hoc-tap.md).

### Đáp án tham khảo — tự trả lời trước, rồi mới mở ra đối chiếu

<details>
<summary><b>Câu hỏi 1</b> — File nào quyết định: route gateway, hostname Ingress, số replica prod, kích thước RDS dev?</summary>

| Quyết định | File quyết định | Bằng chứng |
|---|---|---|
| **Route gateway** (path nào đi service nào) | [apps/backend/api-gateway/src/main/resources/application.yml](../apps/backend/api-gateway/src/main/resources/application.yml) | Khối `spring.cloud.gateway.routes` (dòng 6–24): 4 route theo `Path=...` + `StripPrefix=1` bỏ tiền tố `/api` |
| **Hostname Ingress** | **Hai file cùng quyết định** — đây là điểm hay của Kustomize | Base [`infrastructure/kubernetes/base/ingress.yaml:19`](../infrastructure/kubernetes/base/ingress.yaml) chỉ có placeholder `host: REPLACE_ME_HOST`. Giá trị **thật** do overlay từng môi trường **patch đè lên**: [`overlays/dev/kustomization.yaml:97-102`](../infrastructure/kubernetes/overlays/dev/kustomization.yaml) đặt `dev.bss.example.com`; staging/prod có patch tương tự với `staging.bss.example.com` / `bss.example.com` |
| **Số replica prod** | [`infrastructure/kubernetes/overlays/prod/kustomization.yaml:46-53`](../infrastructure/kubernetes/overlays/prod/kustomization.yaml) | Field `replicas:` đặt `count: 3` cho 6/7 service — **để ý:** `admin-console` chỉ `count: 2`, không đồng bộ với các service kia (đáng ghi vào nhật ký khi bạn dọn dẹp overlay) |
| **Kích thước RDS dev** | [`infrastructure/terraform/environments/dev/main.tf:100-116`](../infrastructure/terraform/environments/dev/main.tf) | Khối `module "rds"`: `instance_class = "db.t3.micro"`, `allocated_storage = 20` (GB), `multi_az = false` |

⚠️ Bẫy cần nhớ: overlay dev đặt `replicas: count: 1`, nhưng **HPA ở base** ([`base/customer-service/hpa.yaml:11`](../infrastructure/kubernetes/base/customer-service/hpa.yaml)) đặt `minReplicas: 2` cho mọi môi trường — HPA sẽ **ghi đè ngược lại** con số 1 của overlay ngay khi autoscaler chạy lần đầu. Đây chính là **B-22** ở [bài 01](01-hien-trang-va-danh-sach-loi.md). Bài học chung: với Kustomize, "ai quyết định giá trị cuối cùng" nhiều khi phải cộng dồn từ **2-3 file khác nhau**, không nằm gọn trong 1 chỗ.

</details>

<details>
<summary><b>Câu hỏi 2</b> — Vì sao order → billing dùng hàng đợi thay vì gọi HTTP trực tiếp?</summary>

**Lý do 1 — Tách rời thất bại (decoupling failure), order không bị "kéo sập" theo billing.**
Nếu `order-management` gọi HTTP thẳng sang `billing-service` để xin tạo hóa đơn, thì khi billing chậm hoặc down, request đặt hàng của khách sẽ bị treo hoặc trả lỗi — dù về bản chất "đặt hàng" và "xuất hóa đơn" là hai việc **độc lập** đối với khách hàng. Nhìn vào [`OrderService.java:39-73`](../apps/backend/order-management/src/main/java/com/bss/order/service/OrderService.java): `create()` chỉ lưu `product_order` + ghi 1 dòng vào `event_outbox` **trong cùng transaction**, rồi `return` ngay — không có dòng code nào gọi tới billing. Khách nhận `201 Created` bất kể billing sống hay chết. 🔁 Đối chiếu với đồ án của bạn: `order-service` gọi đồng bộ sang `payment-service` — nếu `payment-service` down, `order-service` cũng lỗi theo.

**Lý do 2 — Hàng đợi tự động giữ và thử lại, không cần order tự cài retry/circuit breaker.**
SQS giữ message tối đa **4 ngày** (`message_retention_seconds = 345600` — [`eventbridge/main.tf:30`](../infrastructure/terraform/modules/eventbridge/main.tf)) và tự động giao lại nếu consumer chưa xóa (ACK) trong `visibility_timeout_seconds` (60s), tối đa **5 lần** (`max_receive_count = 5` — [`eventbridge/variables.tf:17`](../infrastructure/terraform/modules/eventbridge/variables.tf)) trước khi rơi vào DLQ. Nếu `billing-service` restart, deploy, hoặc quá tải tạm thời, sự kiện `OrderCompleted` **vẫn nằm chờ trong queue** — billing tự xử lý tiếp khi nó khỏe lại. Gọi HTTP trực tiếp thì `order-management` phải **tự viết** logic retry + timeout + circuit breaker (Resilience4j) cho việc này.

**Lý do phụ (đáng nhắc thêm nếu được hỏi sâu hơn):**
- **Mở rộng không sửa code cũ:** muốn thêm một consumer mới (vd. `notification-service` gửi email xác nhận) chỉ cần thêm 1 EventBridge rule + 1 SQS queue trỏ vào cùng bus `bss-dev-events` — `order-management` không phải sửa gì (nó chỉ biết "phát sự kiện", không biết "ai đang nghe").
- **San tải theo thời gian (load leveling):** nếu order tạo ra 1000 đơn/giây nhưng billing chỉ xử lý nổi 100/giây, hàng đợi tự nhiên trở thành bộ đệm — billing xử lý dần theo khả năng của nó thay vì bị dội 1000 request cùng lúc.

**Đánh đổi phải trả (đừng quên nói khi phỏng vấn):** dữ liệu chỉ **nhất quán sau cùng** (eventual consistency — khách phải đợi vài giây mới thấy hóa đơn, đúng như [`BillsPage.tsx`](../apps/frontend/web-portal/src/pages/BillsPage.tsx) phải `refetchInterval: 5000` để poll), và consumer bắt buộc phải **idempotent** vì SQS giao *at-least-once* (có thể nhận trùng message) — đây chính là lý do tồn tại của `processed_event` trong billing.

</details>

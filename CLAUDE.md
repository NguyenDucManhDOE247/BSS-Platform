# CLAUDE.md — BSS Platform on GKE

> File này là **bản kế hoạch tổng thể** đồng thời là **bộ quy ước làm việc** cho Claude Code khi tương tác với repo này. Mọi quyết định kiến trúc, công nghệ, quy ước code và lộ trình triển khai đều được mô tả ở đây để Claude và lập trình viên có cùng một bản đồ.

---

## 1. Mục tiêu dự án

Xây dựng một **Business Support System (BSS)** chuẩn viễn thông theo kiến trúc **microservices**, triển khai trên **Google Kubernetes Engine (GKE) Autopilot**, vận hành bằng **Infrastructure-as-Code**, có **CI/CD tự động** và **observability** đầy đủ.

Mục đích kép:
1. **Portfolio học tập** — chứng minh kỹ năng platform engineering end-to-end (cloud, K8s, IaC, CI/CD, observability, security).
2. **Tham chiếu kiến trúc** — bộ khung có thể mở rộng thành một BSS hoạt động thật trong dự án telco.

**Không phải là** một toy project. Mọi component phải chạy được trên GCP thật, có chi phí thật, và tuân theo best practice của production.

---

## 2. Kiến trúc tổng thể

### 2.1 Sơ đồ logic

```
   Client (web/mobile/B2B partners)
            │
            ▼  HTTPS
   ┌────────────────────┐
   │  GCE Ingress / GW  │  (Google Cloud Load Balancer + Managed Certs)
   └─────────┬──────────┘
             │
   ┌─────────▼──────────────────────────────────────────────┐
   │  GKE Autopilot — namespace: bss                        │
   │  ┌──────────────┐  ┌──────────────┐                    │
   │  │ customer-svc │  │ product-svc  │   (REST: TMF629/620)│
   │  └──────┬───────┘  └──────┬───────┘                    │
   │         │                 │                            │
   │  ┌──────▼───────┐  ┌──────▼───────┐                    │
   │  │  order-svc   │──│ billing-svc  │  (REST + events)   │
   │  └──────┬───────┘  └──────┬───────┘                    │
   └─────────┼─────────────────┼────────────────────────────┘
             │                 │
             ▼                 ▼
      ┌─────────────┐    ┌─────────────┐
      │  Cloud SQL  │    │  Pub/Sub    │  (event bus: order→billing)
      │ (Postgres)  │    │             │
      └─────────────┘    └─────────────┘

   Observability: Prometheus + Grafana + OpenTelemetry → Cloud Trace
   Secrets:       Secret Manager + Workload Identity (no JSON keys)
   Registry:      Artifact Registry (asia-southeast1)
```

### 2.2 Lý do lựa chọn từng thành phần

| Lớp | Lựa chọn | Lý do |
|---|---|---|
| Cloud | **GCP** | Hệ sinh thái managed services tốt cho startup/portfolio; GKE Autopilot vận hành đơn giản |
| Orchestration | **GKE Autopilot** | Pay-per-pod, không cần quản lý node, tự bật shielded nodes + private cluster |
| Compute | **Java 21 + Spring Boot 3** | Telco Việt Nam (Viettel, VNPT, FPT) chủ yếu dùng Java; ecosystem TM Forum SDK trưởng thành |
| Build | **Maven** (đã có), có thể nâng lên **Gradle** ở Phase 8 | Bắt đầu đơn giản |
| Container | **Distroless** (gcr.io/distroless/java21) | Giảm CVE, nhẹ, không có shell |
| DB | **Cloud SQL for PostgreSQL** | Managed, có HA, IAM auth, point-in-time recovery |
| IaC | **Terraform 1.7+** | Tiêu chuẩn ngành, state có thể đẩy lên GCS |
| K8s deploy | **Kustomize** | Built-in trong kubectl; đủ cho 4 service, không cần Helm rườm rà |
| CI/CD | **GitHub Actions + WIF** | Không dùng JSON key, OIDC federation an toàn hơn |
| Observability | **kube-prometheus-stack + OTel** | Chuẩn de-facto của K8s; OTel cho tracing đa ngôn ngữ |
| Event bus | **Pub/Sub** (Phase 7) | Managed, không phải tự nuôi Kafka |
| Service mesh | **Không dùng (cho đến >10 services)** | Istio quá nặng cho 4 service; kích hoạt khi cần mTLS/traffic shaping |

> **Nguyên tắc:** không over-engineer. Service mesh, multi-region, Spinnaker, Argo Rollouts — đều **để dành** đến khi có nhu cầu rõ ràng.

---

## 3. Domain — BSS theo TM Forum Open APIs

| Service | Trách nhiệm | TMF API | Trạng thái |
|---|---|---|---|
| `customer-service` | Quản lý vòng đời khách hàng, liên hệ, identity | **TMF629** | ✅ Đã có scaffold |
| `product-catalog` | Gói cước, ưu đãi, pricing | **TMF620** | ⏳ Phase 6 |
| `order-management` | Capture & orchestration đơn hàng | **TMF622** | ⏳ Phase 6 |
| `billing-service` | Charging, invoicing, payment | **TMF678** | ⏳ Phase 6 |

### 3.1 Tương tác giữa các service

- **Synchronous (REST):** customer ← product ← order (đọc tham chiếu).
- **Asynchronous (Pub/Sub):** order → billing (sự kiện `OrderCompleted`, `PaymentReceived`).
- **Không gọi chéo DB** — mỗi service sở hữu schema riêng (database-per-service). Cùng một Cloud SQL instance nhưng các database/schema khác nhau để tiết kiệm chi phí ở giai đoạn đầu; tách instance khi >100 QPS.

### 3.2 Contract & versioning

- Mọi API public phát hành **OpenAPI 3.1** trong `services/<svc>/src/main/resources/openapi/`.
- Versioning theo URI: `/tmf-api/customerManagement/v4/...`.
- **Backward-compatible only** — thêm trường, không xóa; deprecate trước 1 release rồi mới xóa.

---

## 4. Hạ tầng GCP — chi tiết

### 4.1 Resources được Terraform quản lý

| Resource | Module/File | Ghi chú |
|---|---|---|
| Project services (API enablement) | `main.tf` | container, sqladmin, artifactregistry, secretmanager, iamcredentials |
| VPC + subnets (private) | `network.tf` | 1 subnet `/24` cho nodes + 2 secondary range cho pods/services |
| GKE Autopilot cluster | `gke.tf` | Private cluster, master authorized networks, workload identity bật |
| Cloud SQL PostgreSQL 15 | `cloud_sql.tf` | Private IP, regional HA tắt ở dev, bật ở prod |
| Artifact Registry | `artifact_registry.tf` | `asia-southeast1-docker.pkg.dev/<project>/bss-docker` |
| IAM Service Accounts | `main.tf` | `bss-deployer` (CI/CD), `bss-customer-sa` (Workload Identity) |
| Workload Identity bindings | `gke.tf` | KSA `bss/customer-service-sa` ↔ GSA `bss-customer-sa@...` |

### 4.2 Networking

- **Private cluster** — node không có public IP.
- **Master authorized networks** — chỉ IP của lập trình viên/CI được hit control plane.
- **Cloud NAT** — node truy cập internet (pull image, gọi GCP APIs).
- **VPC peering** — Cloud SQL → cluster VPC qua private services access.

### 4.3 Security baseline

- **No JSON service-account keys.** Mọi xác thực: Workload Identity (pod) hoặc WIF (GitHub Actions).
- **Secret Manager** lưu DB password, OAuth client secrets. Pod mount qua CSI driver.
- **Binary Authorization** (Phase 8) — chỉ cho phép deploy image đã ký bởi CI.
- **Pod Security Standards: restricted** ở namespace `bss`.
- **NetworkPolicy** — mặc định deny, whitelist theo cặp service.

### 4.4 Regions & môi trường

| Env | Region | Cluster | Cloud SQL tier | Cost ước tính/ngày |
|---|---|---|---|---|
| `dev` | `asia-southeast1` (Singapore) | Autopilot, 1 region | `db-f1-micro` | ~$5 USD |
| `prod` | `asia-southeast1` | Autopilot, regional | `db-custom-2-7680` HA | ~$40 USD |

> **Cost discipline:** chạy `terraform destroy` mỗi tối khi đang học. Có script `scripts/teardown.sh` để tự động hóa.

---

## 5. Tech stack đầy đủ

```yaml
language:        Java 21 (LTS)
framework:       Spring Boot 3.2.x
build:           Maven 3.9 (multi-module ở Phase 6)
db_access:       Spring Data JPA + Hibernate 6
migration:       Flyway (thêm ở Phase 1.5)
testing:
  unit:          JUnit 5 + Mockito
  integration:   Testcontainers (Postgres)
  contract:      Spring Cloud Contract (Phase 6)
  e2e:           Karate (Phase 7)
container:       Distroless java21
orchestrator:    Kubernetes 1.29 (GKE Autopilot)
k8s_pkg:         Kustomize (base + overlays/dev|staging|prod)
iac:             Terraform 1.7, hashicorp/google 5.x
ci_cd:           GitHub Actions + Workload Identity Federation
image_scan:      Trivy (CI) + GCP Container Analysis (registry)
observability:
  metrics:       Prometheus (kube-prometheus-stack)
  dashboards:    Grafana
  logs:          Cloud Logging (stdout → Fluent Bit → GCL)
  tracing:       OpenTelemetry Java agent → Cloud Trace
  alerting:      Alertmanager → Slack/Discord
secrets:         Secret Manager + Secrets Store CSI Driver
events:          Pub/Sub (Phase 7)
api_gateway:     GCE Ingress (Phase 3), nâng cấp Gateway API ở Phase 8
```

---

## 6. Cấu trúc thư mục

```
bss-platform-gke/
├── CLAUDE.md                  ← file này (bản kế hoạch + quy ước)
├── README.md                  ← giới thiệu cho recruiter/người mới
├── Makefile                   ← shortcut cho mọi tác vụ
├── LICENSE
├── terraform/                 ← IaC cho toàn bộ GCP
│   ├── main.tf
│   ├── network.tf
│   ├── gke.tf
│   ├── cloud_sql.tf
│   ├── artifact_registry.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── services/                  ← Mỗi microservice 1 thư mục
│   ├── customer-service/      ← TMF629 — tham chiếu mẫu
│   ├── product-catalog/       ← TMF620 (Phase 6)
│   ├── order-management/      ← TMF622 (Phase 6)
│   └── billing-service/       ← TMF678 (Phase 6)
├── kubernetes/
│   ├── base/                  ← Manifests chung (Kustomize base)
│   └── overlays/
│       ├── dev/
│       ├── staging/           ← Phase 4
│       └── prod/              ← Phase 4
├── monitoring/
│   ├── prometheus/values.yaml
│   ├── grafana/dashboards/
│   └── alerts/
├── .github/workflows/         ← CI/CD (Phase 4)
│   ├── ci.yml                 ← test + build trên PR
│   └── cd.yml                 ← deploy khi merge main
├── docs/
│   ├── SETUP.md
│   ├── ROADMAP.md             ← lộ trình học 6 tuần
│   ├── adr/                   ← Architecture Decision Records (Phase 6+)
│   └── POSTMORTEMS.md         ← sự cố và bài học (viết khi gặp bug thật)
└── scripts/                   ← bootstrap, teardown, smoke tests
```

---

## 7. Coding conventions

### 7.1 Java / Spring Boot

- **Package layout per feature**, không phải per layer:
  ```
  com.bss.customer
  ├── controller/        # @RestController
  ├── service/           # business logic
  ├── repository/        # JPA repos
  ├── model/             # JPA entities
  ├── dto/               # request/response (TMF schema)
  └── config/            # @Configuration beans
  ```
- **Constructor injection** (không dùng `@Autowired` field).
- **Records** cho DTO và value objects.
- **`@Transactional`** chỉ ở service layer, không ở controller hoặc repository.
- **Validation** dùng Bean Validation (`@Valid`, `@NotNull`, `@Size`).
- **Logging:** SLF4J + structured logs (JSON ở prod, plain ở dev). Không log PII (số CMND, OTP, password).
- **Tránh** Lombok `@Data` (sinh equals/hashCode không phù hợp với JPA). Dùng `@Getter`, `@Setter`, `@Builder` cụ thể.

### 7.2 REST API

- Path: `/tmf-api/<resource>Management/v<n>/<resource>` đúng chuẩn TM Forum.
- HTTP status codes nghiêm túc — `201` cho create, `204` cho delete, `409` cho conflict, `422` cho validation.
- Error response theo RFC 7807 (Problem Details).
- Pagination: `?offset=0&limit=20`, header `X-Total-Count`.
- Idempotency key cho mọi POST mutating: header `Idempotency-Key`.

### 7.3 Database

- **Flyway migrations** trong `src/main/resources/db/migration/V<timestamp>__<desc>.sql`.
- **Không có migration tự động drop column** — đổi tên qua 2 release (add new → migrate → drop old).
- Primary key: UUID v7 (sortable).
- Mỗi service một schema riêng trong cùng DB (Phase ≤ 6), tách instance khi cần.

### 7.4 Testing

- **Unit tests** chạy <30s tổng cho 1 service. Mock external deps.
- **Integration tests** dùng Testcontainers (Postgres thật, không H2). Đặt trong `src/test/java/.../it/`, suffix `*IT.java`.
- **Contract tests** (Spring Cloud Contract) cho mọi consumer/provider pair từ Phase 6.
- Coverage gate: 80% line, 70% branch (Jacoco trong CI).

### 7.5 Kubernetes

- Mỗi service: `Deployment` + `Service` + `HPA` + `PodDisruptionBudget` + `ServiceAccount`.
- **Probes bắt buộc:** `startupProbe` (cho Spring Boot warmup), `livenessProbe`, `readinessProbe` — tất cả hit `/actuator/health/...`.
- **Resources luôn có cả `requests` lẫn `limits`** (Autopilot bắt buộc).
- **`runAsNonRoot: true`, `readOnlyRootFilesystem: true`**, drop tất cả capabilities.
- **Image tag = git SHA** (không bao giờ `latest`).

### 7.6 Terraform

- Chỉ một state file cho mỗi env. State đặt trên GCS bucket có versioning (`terraform/backend.tf`).
- Module hóa khi có >1 service tái sử dụng cùng pattern (Phase 6).
- `terraform plan` luôn chạy trong CI cho PR sửa `terraform/`. Apply chỉ ở môi trường được duyệt.
- Biến nhạy cảm (DB password) không vào `.tfvars` — sinh ra random và đẩy thẳng vào Secret Manager.

---

## 8. Lộ trình triển khai chi tiết theo Phase

> Mỗi Phase kết thúc bằng một deliverable cụ thể có thể commit/PR. Tham khảo thêm `docs/ROADMAP.md` cho góc nhìn theo tuần.

### Phase 0 — Chuẩn bị (đã xong một phần)
- [x] Scaffold repo, README, LICENSE, Makefile.
- [x] Khung Terraform, customer-service mẫu, monitoring values.
- [ ] Cài đầy đủ: `jdk21`, `maven`, `docker`, `kubectl`, `kustomize`, `terraform 1.7+`, `gcloud SDK`, `jq`, `helm`.
- [ ] Tạo GCP project, bật billing, `gcloud auth application-default login`.

### Phase 1 — Customer service chạy local (Tuần 1)
- [ ] Đọc & hiểu toàn bộ `services/customer-service/`.
- [ ] Bổ sung **Flyway** + migration `V1__init_customer.sql`.
- [ ] `docker compose up postgres`, `mvn spring-boot:run`, test CRUD đầy đủ bằng curl.
- [ ] Viết unit test (≥10 case) + integration test (Testcontainers).
- [ ] Build image distroless, chạy `docker run`, smoke test.

**Deliverable:** `feat(customer-service): TMF629 CRUD + Flyway + Testcontainers`

### Phase 2 — Hạ tầng GCP với Terraform (Tuần 2)
- [ ] `terraform apply` thành công. Vẽ tay sơ đồ network — **đây là bài kiểm tra**.
- [ ] Push state lên GCS bucket (bật versioning).
- [ ] Thêm `tfsec` + `tflint` chạy local trước khi commit.
- [ ] Verify: `kubectl get nodes`, `gcloud sql instances list`, `gcloud artifacts repositories list`.

**Deliverable:** `feat(terraform): GKE Autopilot + Cloud SQL + Artifact Registry + remote state`

### Phase 3 — Deploy lên GKE (Tuần 3)
- [ ] Push image lên Artifact Registry thủ công.
- [ ] `kubectl apply -k kubernetes/overlays/dev`. Debug đến khi pod Ready.
- [ ] Thay static DB secret bằng **Workload Identity + Cloud SQL Auth Proxy**.
- [ ] Tạo `Ingress` (GCE LB) + managed TLS cert.
- [ ] Thêm HPA (CPU 70%, min 2, max 5) + PDB (minAvailable 1).

**Deliverable:** `feat(k8s): deploy customer-service with HPA, PDB, Workload Identity, TLS`

### Phase 4 — CI/CD (Tuần 4)
- [ ] Thiết lập **Workload Identity Federation** GitHub ↔ GCP (không JSON key).
- [ ] `ci.yml`: lint + unit test + integration test + Trivy scan + build image (không push).
- [ ] `cd.yml`: trigger trên merge `main` → push image (tag = git SHA) → `kubectl set image` → `kubectl rollout status`.
- [ ] Cố tình deploy bug, dùng `kubectl rollout undo`. Thêm step rollback tự động khi readiness fail.
- [ ] **Stretch:** environment `prod` với manual approval.

**Deliverable:** `feat(ci): WIF-based CI/CD pipeline with rollback on failure`

### Phase 5 — Observability (Tuần 5)
- [ ] Install kube-prometheus-stack qua Helm với `monitoring/prometheus/values.yaml`.
- [ ] ConfigMap `bss-dashboards` import vào Grafana.
- [ ] Apply `monitoring/alerts/bss-alerts.yaml`, kích hoạt thủ công `BssHighErrorRate`.
- [ ] Cấu hình Alertmanager → webhook Slack/Discord cá nhân.
- [ ] Tích hợp **OpenTelemetry Java agent** → Cloud Trace.
- [ ] Định nghĩa **SLI/SLO** đầu tiên (availability 99.5%, p99 latency <500ms) trong `docs/SLO.md`.

**Deliverable:** `feat(observability): full metrics/logs/traces with SLO-based alerts`

### Phase 6 — Hoàn thiện 3 service còn lại (Tuần 6–7)
- [ ] Refactor `services/` thành **Maven multi-module** với `bss-common` (DTO + exception handlers chung).
- [ ] Scaffold `product-catalog`, `order-management`, `billing-service` theo template customer-service.
- [ ] Mỗi service: schema DB riêng, K8s manifest riêng, dashboard Grafana riêng.
- [ ] Viết **ADR-001: REST vs event-driven cho order→billing** trong `docs/adr/`.
- [ ] Viết contract test cho order ↔ billing.

**Deliverable:** `feat(platform): 4 TMF services with shared bss-common module`

### Phase 7 — Event-driven cho order flow (Tuần 8)
- [ ] Terraform tạo topic `bss-order-events` + subscription `billing-sub` trên Pub/Sub.
- [ ] `order-service` publish `OrderCompleted` (CloudEvents format).
- [ ] `billing-service` subscribe và tạo invoice idempotently.
- [ ] Bổ sung dead-letter topic + alert khi DLQ > 0.
- [ ] Cập nhật sơ đồ kiến trúc trong README.

**Deliverable:** `feat(events): Pub/Sub-based order→billing flow with DLQ`

### Phase 8 — Production hardening
- [ ] Bật **Binary Authorization** + image signing với cosign.
- [ ] **NetworkPolicy** mặc định deny, whitelist từng cặp.
- [ ] **Pod Security Standards: restricted**.
- [ ] Bật **Cloud SQL HA** ở overlay `prod`.
- [ ] **Multi-AZ + PDB** đầy đủ.
- [ ] Chaos test cơ bản: `kubectl delete pod` ngẫu nhiên trong giờ tải cao.

**Deliverable:** `feat(security): binauthz + network policies + PSS restricted`

### Phase 9 — Đánh bóng portfolio
- [ ] Viết `docs/POSTMORTEMS.md` về bug khó nhất từng gặp.
- [ ] Quay video demo 5 phút (deploy → smoke → break → recover).
- [ ] Viết blog post "Building a telecom BSS on GKE in N weeks".
- [ ] Mời 1–2 senior engineer review repo, xử lý feedback.

**Deliverable:** Repo sẵn sàng phỏng vấn — narratable end-to-end.

---

## 9. Quy ước cho Claude khi làm việc với repo này

### 9.1 Nguyên tắc chung
- **Bám lộ trình theo Phase.** Không nhảy cóc Phase nếu user chưa khẳng định.
- **Hỏi trước khi tốn tiền.** Bất kỳ thao tác `terraform apply`, `gcloud ... create`, `kubectl create` đụng vào tài nguyên thật trên GCP — phải confirm với user trước.
- **Không bao giờ commit secret** — `.env`, `terraform.tfvars`, JSON keys phải nằm trong `.gitignore`.
- **Mọi `terraform apply` đi kèm `plan` để user duyệt.**
- **Khi user mơ hồ**, hỏi 1 câu làm rõ thay vì đoán.

### 9.2 Khi tạo service mới
1. Copy cấu trúc từ `customer-service` làm template.
2. Đổi `groupId`, `artifactId`, package `com.bss.<svc>`, port, DB schema.
3. Tạo Flyway migration `V1__init_<svc>.sql`.
4. Viết tối thiểu: 1 controller, 1 service, 1 repository, 1 entity, 1 DTO, 1 integration test pass.
5. Thêm Kustomize base ở `kubernetes/base/<svc>-*.yaml`.
6. Thêm dashboard skeleton ở `monitoring/grafana/dashboards/<svc>.json`.

### 9.3 Khi sửa Terraform
1. Luôn `terraform fmt && terraform validate` trước khi commit.
2. Nếu thêm resource mới — cập nhật `docs/SETUP.md` phần "What you'll be charged for".
3. Resource có chi phí cao (HA Cloud SQL, GKE Standard, BigQuery slot reservation) — **cảnh báo user trong PR description**.

### 9.4 Khi viết K8s manifest
1. Thêm vào `kubernetes/base/`, không thêm thẳng vào overlay.
2. Mọi container phải có resources + probes + securityContext non-root.
3. Image tag dùng placeholder `${IMAGE_TAG}` để Kustomize `images:` xử lý.

### 9.5 Khi viết test
- Bug fix → kèm test reproduce bug (test fail trước khi sửa, pass sau khi sửa).
- Feature mới → kèm unit test cho happy path + ≥2 edge case + integration test cho contract.
- Không mock framework (Spring, JPA, HTTP client) ở integration test — dùng Testcontainers.

### 9.6 Khi cập nhật tài liệu
- Sửa kiến trúc → cập nhật cả sơ đồ trong README và CLAUDE.md.
- Quyết định kiến trúc lớn → tạo ADR mới trong `docs/adr/NNNN-<slug>.md`.
- **Không tạo file markdown mới** trừ khi user yêu cầu hoặc đang ở Phase tạo doc cụ thể.

### 9.7 Trả lời câu hỏi & giải thích
- User là người Việt — trả lời tiếng Việt, giữ thuật ngữ kỹ thuật bằng tiếng Anh.
- Khi giải thích lựa chọn kiến trúc — luôn nói rõ **trade-off**, không chỉ ưu điểm.
- Khi user nói "build cái này đi" — kiểm tra Phase hiện tại, nếu vượt Phase → đề xuất chia nhỏ.

---

## 10. Best practices ràng buộc

### 10.1 Security
- ❌ Không có JSON service account key trong repo, máy local, hay CI.
- ❌ Không có secret cleartext trong manifest hay env var (dùng Secret Manager + CSI).
- ❌ Không log password, OTP, token, số CCCD/CMND.
- ✅ Mọi image build trong CI phải qua Trivy, fail nếu có CVE HIGH/CRITICAL chưa fix.
- ✅ Pod chạy non-root, readOnly root FS, drop all capabilities.

### 10.2 Reliability
- ✅ Mọi service ≥2 replica ở prod, có PDB minAvailable=1.
- ✅ HPA dựa trên CPU + custom metric (req/s) khi sẵn sàng.
- ✅ Mọi external call (DB, Pub/Sub, REST) có timeout + retry + circuit breaker (Resilience4j).
- ✅ SLI/SLO định nghĩa rõ, có error budget burn-rate alert.

### 10.3 Cost
- ✅ Dev cluster `terraform destroy` mỗi tối.
- ✅ Cloud SQL dev tier `db-f1-micro`, không HA.
- ✅ Image pull policy `IfNotPresent` để tránh egress charge.
- ⚠️ Cảnh báo nếu tổng cost/tháng dev vượt $50 — kiểm tra `gcloud billing accounts list-usage`.

### 10.4 Operability
- ✅ Mọi service expose `/actuator/health`, `/actuator/prometheus`, `/actuator/info`.
- ✅ Mọi service có dashboard Grafana riêng với 4 RED metric (Rate, Errors, Duration) + saturation.
- ✅ Mọi alert có runbook URL trong annotation `runbook_url`.
- ✅ Log structured JSON ở prod, có `trace_id` để correlate với Cloud Trace.

---

## 11. Lệnh thường dùng (cheatsheet)

```bash
# Toàn bộ tác vụ chính đã được wrap trong Makefile:
make help                       # liệt kê targets

# Local dev
make svc-build                  # build JAR
make svc-run                    # chạy local với Postgres
make image-build TAG=v0.1.0     # build container

# GCP infra
make tf-init && make tf-plan
make tf-apply                   # CHỈ CHẠY KHI ĐÃ DUYỆT
make tf-destroy                 # tear down mỗi tối

# K8s
make image-push TAG=$(git rev-parse --short HEAD)
make deploy-dev
make smoke

# Monitoring
make monitoring-install
make grafana                    # localhost:3000
```

---

## 12. Tài liệu tham khảo

- **TM Forum Open APIs** — https://www.tmforum.org/oda/open-apis/
- **GKE Autopilot docs** — https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview
- **GKE Security best practices** — https://cloud.google.com/kubernetes-engine/docs/concepts/security-overview
- **Workload Identity Federation** — https://cloud.google.com/iam/docs/workload-identity-federation
- **Spring Boot 3 Reference** — https://docs.spring.io/spring-boot/docs/3.2.x/reference/html/
- **Kustomize docs** — https://kubectl.docs.kubernetes.io/guides/introduction/kustomize/
- **Site Reliability Workbook (Google) — SLO chapter** — https://sre.google/workbook/implementing-slos/

---

## 13. Trạng thái hiện tại (cập nhật khi cần)

- **Ngày bắt đầu kế hoạch:** 2026-05-22
- **Phase hiện tại:** 0 → 1 (đang chuẩn bị môi trường local + làm chủ customer-service)
- **GCP project ID:** chưa tạo
- **Người maintain:** chủ repo (1 người, học part-time)
- **Ngân sách dev/tháng:** mục tiêu < $50 USD

> Khi chuyển Phase, cập nhật mục này để Claude biết bối cảnh hiện tại.

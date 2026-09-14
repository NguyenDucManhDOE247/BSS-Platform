# 01 — Hiện trạng thật của dự án & danh sách lỗi đã kiểm chứng

> Mục tiêu bài: biết **chính xác** thầy đã làm đến đâu, cái gì chạy thật, cái gì mới chỉ "trên giấy",
> và có một danh sách việc cần sửa có mã số (B-xx) để lộ trình [20](20-lo-trinh-hoan-thanh.md) tham chiếu.

> 🙏 Về cách nhìn: repo được thầy dựng rất nhanh (khoảng 1 tuần, cùng Claude Code — ghi rõ trong README) với **thiết kế tốt và phạm vi rộng**. Việc cấu hình "viết ra" nhưng "chưa chạy" có lỗi tích hợp là **hoàn toàn bình thường** ở giai đoạn scaffold. Công việc của bạn — biến scaffold thành hệ thống chạy thật — chính là phần kỹ năng DevOps mà nhà tuyển dụng trả tiền cho.

---

## 1. Dòng thời gian tiến độ (từ `git log`)

| Ngày | Commit tiêu biểu | Nội dung |
|---|---|---|
| 22/05/2026 | `chore: initialize git repo...` → `docs: rewrite CLAUDE.md ... for AWS` | Dựng monorepo, **chuyển dự án từ GCP sang AWS** (đây là lý do `docs/ROADMAP.md` còn nói GKE), 7 module Terraform + 3 env, K8s ALB/IRSA, platform addons, CI/CD 7 workflow, docker-compose + LocalStack, scripts |
| 28/05/2026 | `feat(customer-service)` … `feat(api-contracts)` | Viết đầy đủ 4 service nghiệp vụ (Flyway, Testcontainers), outbox, idempotent consumer, manifest 6 service, frontend các trang, OpenAPI |
| 16/06/2026 | (không commit — thư mục `course/`) | Soạn đề cương 15 module |
| 09/09/2026 | `Initial commit` | Thêm tài liệu kiến trúc tiếng Việt + ảnh; `.gitignore` thêm `course/`; **vô tình làm mất quyền thực thi của 5 file `.sh`** (B-07) |

Bằng chứng "đã từng compile": thư mục `target/classes` của cả 5 service có file `.class` (ngày 22/05) → code Java **đã từng biên dịch thành công** trên máy thầy. Không có bằng chứng đã từng `docker build`, `terraform apply`, hay chạy workflow GitHub Actions.

---

## 2. Bảng "Tuyên bố ↔ Thực tế"

Cách tôi kiểm chứng: đọc toàn bộ file + chạy thật trên máy bạn `terraform fmt -check`, `terraform init -backend=false`, `terraform validate` (trên bản sao), `kubectl kustomize` 3 overlay. Docker Desktop đang tắt nên **chưa chạy thử** `docker build`/`mvn verify` — phần đó là lab đầu tiên của bạn.

| Thành phần | CLAUDE.md / README nói | Thực tế kiểm chứng | Mức sẵn sàng |
|---|---|---|---|
| Code 4 service | ✅ hoàn chỉnh + IT | Code đầy đủ, logic hợp lý, **có 1 lỗi mất dữ liệu** (B-10) và vài lỗi thiết kế (B-11..13) | 🟡 75% |
| api-gateway | ✅ routes configured | Chỉ route; chưa auth/rate-limit/timeout; route rút gọn `/api/customers/**` trả 404 (B-03) | 🟡 50% |
| Frontend | ✅ các trang gọi API thật | Code trang OK; **CI sẽ đỏ** (không lockfile/eslint/test — B-04); admin dưới `/admin` hỏng asset (B-06) | 🟡 60% |
| Dockerfile | ✅ multi-stage, non-root | **Cả 5 Dockerfile backend không build được** (B-01); Nginx non-root lỗi khi `docker run` (B-05) | 🔴 20% |
| Local dev | ✅ "builds and runs end-to-end" | Chỉ chạy được **1 service** một lúc (cùng port 8080, 1 DB_URL, gateway trỏ DNS K8s — B-02) | 🔴 30% |
| Kustomize | ✅ 3 overlay | **Build được** cả 3 overlay (41 object mỗi env). Nhưng: thiếu 4 Secret (B-20), HPA ghi đè replicas (B-22), HTTPS không có cert (B-23) | 🟡 60% |
| Terraform | ✅ 7 module + 3 env | 🔴 **`terraform init` lỗi** (B-30); vá xong thì `validate` lỗi (B-31); vá tiếp thì validate pass. Thiết kế mạng dev không chạy được (B-32), xung đột state ECR (B-33), thiếu IAM addon (B-35) | 🔴 35% |
| Platform addons | ✅ Helm values | Values có sẵn nhưng thiếu IAM, lệnh Karpenter sai, không có ServiceMonitor → Grafana trống (B-40) | 🔴 30% |
| CI | ✅ 4 workflow | backend: docker build đỏ; frontend: đỏ; terraform: đỏ (fmt 6 file + tfsec + biến bắt buộc); k8s: nhiều khả năng xanh | 🔴 25% |
| CD | ✅ build once, deploy many | Lỗi thiết kế nền tảng: không lưu phiên bản đã deploy (B-50, B-51); smoke test không bao giờ fail (B-52); deployer role không vào được EKS (B-34) | 🔴 15% |
| Observability | ✅ Prometheus+Grafana+CW+X-Ray | Có alert/dashboard mẫu tốt, nhưng chưa có đường thu metric/trace thực sự (B-40, B-16, B-42) | 🔴 25% |
| AWS account | ⏳ chưa tạo | Máy bạn có `~/.aws/credentials` (có thể từ đồ án) — **kiểm tra account nào trước khi apply** | — |

**Kết luận thẳng thắn:** theo lộ trình trong CLAUDE.md, dự án đang ở **đầu Phase 1** (chưa chạy local end-to-end), không phải "Phase 1 hoàn thành". Toàn bộ Phase 2–10 chưa bắt đầu.

---

## 3. Những điều **tốt** trong dự án (để học theo)

Công bằng mà nói, thiết kế có rất nhiều quyết định chuẩn production mà bạn nên hiểu và giữ:

1. **Transactional Outbox** + **Idempotent Consumer** — hai pattern cốt lõi của hệ thống event-driven, ít dự án sinh viên có.
2. **Flyway sở hữu schema** (`ddl-auto: validate`) — không để Hibernate tự sửa DB.
3. **Testcontainers** thay vì DB giả (H2/MongoMemoryServer) → test sát production hơn.
4. **3 probe + resources + securityContext đầy đủ** trên mọi container; `maxUnavailable: 0`; `topologySpreadConstraints` theo AZ.
5. **IRSA per-service** với trust policy khóa theo `namespace:serviceaccount` — đúng least privilege.
6. **GitHub OIDC** — không có access key trong CI.
7. **ECR IMMUTABLE + lifecycle**, **image tag = git SHA**, **tag-based promotion** với duyệt tay ở prod.
8. **Cost-awareness**: nightly destroy, log retention theo môi trường, X-Ray sampling theo môi trường.
9. **RFC 7807 ProblemDetail**, `X-Total-Count`, HTTP status đúng (201/204/409/422).
10. Tài liệu hóa quyết định kiến trúc có trade-off (CLAUDE.md mục 2).

---

## 4. Danh sách lỗi (B-xx)

**Mức độ:** 🔴 **P0** = chặn hoàn toàn, không làm bước sau được · 🟠 **P1** = chạy được nhưng sai hành vi/nguy hiểm · 🟡 **P2** = chất lượng, chi phí, nhất quán.

Mỗi lỗi ghi: **Bằng chứng** (file:dòng) · **Vì sao quan trọng** (bài học rút ra) · **Hướng sửa** (gợi ý — bạn tự làm) · **Bài** chuyên sâu.

### 4.1 Build, môi trường local & test (B-01 → B-09)

#### 🔴 B-01 — Cả 5 Dockerfile backend không build được
- **Bằng chứng:** [customer-service/Dockerfile:15-18](../apps/backend/customer-service/Dockerfile) `COPY .mvn/` và `./mvnw` — repo **không có** Maven Wrapper. 4 Dockerfile còn lại (vd. [order-management/Dockerfile](../apps/backend/order-management/Dockerfile)) gọi `mvn` trên image `eclipse-temurin:21-jdk-jammy` — image này **chỉ có JDK, không có Maven** → `mvn: not found`. (Dòng `mvn dependency:go-offline ... || true` còn che mất lỗi ở bước đầu.)
- **Vì sao quan trọng:** CI backend và toàn bộ CD phụ thuộc bước này. Bài học: `|| true` là "thuốc an thần" nguy hiểm — nó giấu lỗi.
- **Hướng sửa:** stage build dùng `maven:3.9-eclipse-temurin-21`, hoặc sinh Maven Wrapper (`mvn -N wrapper:wrapper`) và commit `mvnw` + `.mvn/wrapper/maven-wrapper.properties`. Thêm `.dockerignore` (bỏ `target/`).
- **Bài:** [12](12-docker-va-local-dev.md)

#### 🔴 B-02 — Không thể chạy nhiều service cùng lúc ở local
- **Bằng chứng:** mọi `application.yml` đều `server.port: 8080`; [deploy/.env.example:5](../deploy/.env.example) chỉ có **một** `DB_URL` (trỏ DB `customer`) nhưng bị dùng chung cho mọi service; `.env.example` đặt `SPRING_PROFILES_ACTIVE=local` nhưng **không có** `application-local.yml` nào; gateway route tới `*.bss.svc.cluster.local` (chỉ tồn tại trong K8s).
- **Vì sao quan trọng:** Lab 2.3 của course (flow customer → order → invoice qua gateway) không thể làm. Bài học: "12-factor config" — cấu hình phải tách theo môi trường.
- **Hướng sửa:** mỗi service thêm `application-local.yml` (port 8081–8084 + DB riêng + `AWS_ENDPOINT_URL`), gateway thêm profile `local` route tới `http://localhost:808x`. Viết script `scripts/e2e-local.sh`.
- **Bài:** [10](10-backend-java-spring.md), [12](12-docker-va-local-dev.md)

#### 🟠 B-03 — Route rút gọn của gateway trả 404
- **Bằng chứng:** [api-gateway application.yml:10,24](../apps/backend/api-gateway/src/main/resources/application.yml): predicate `Path=/api/customers/**` + `StripPrefix=1` → request `/api/customers/x` thành `/customers/x`, service **không có** path này. Chỉ nhánh `/api/tmf-api/...` chạy. Tài liệu [backend_connections.md](../docs/architecture/backend_connections.md) lại mô tả route rút gọn.
- **Hướng sửa:** bỏ route rút gọn, hoặc dùng `RewritePath`. Thêm test cho gateway.
- **Bài:** [10](10-backend-java-spring.md)

#### 🟠 B-04 — Frontend: CI chắc chắn đỏ, build không tái lập
- **Bằng chứng:** không có `package-lock.json` → `ci-frontend.yml:47-48` bật cache npm theo lockfile không tồn tại → setup-node lỗi; `npm run lint` gọi ESLint nhưng **không có file cấu hình ESLint**; `npm test` (vitest) **không có file test nào** → exit 1. Dockerfile dùng `npm ci || npm install` (lại "thuốc an thần").
- **Hướng sửa:** `npm install` một lần → commit lockfile; thêm `.eslintrc.cjs` (hoặc `eslint.config.js`); viết ít nhất 1 test vitest; bỏ `|| npm install`.
- **Bài:** [11](11-frontend-react-vite.md)

#### 🟠 B-05 — Nginx chạy non-root sẽ không khởi động khi `docker run`
- **Bằng chứng:** [web-portal/Dockerfile:14-20](../apps/frontend/web-portal/Dockerfile) dùng `nginx:1.27-alpine`, chuyển sang user uid 1000 nhưng `nginx.conf` mặc định của image vẫn ghi pid vào `/run/nginx.pid` (thư mục của root) → `Permission denied`. Trên K8s được "cứu" vì manifest mount `emptyDir` vào `/var/run`, nhưng lab `docker run` ở local sẽ lỗi.
- **Hướng sửa:** dùng image `nginxinc/nginx-unprivileged` (đã cấu hình sẵn cho non-root, port 8080).
- **Bài:** [11](11-frontend-react-vite.md), [12](12-docker-va-local-dev.md)

#### 🟡 B-06 — admin-console dưới `/admin` sẽ tải nhầm asset
- **Bằng chứng:** [ingress.yaml:29-35](../infrastructure/kubernetes/base/ingress.yaml) route `/admin` → admin-console, nhưng Vite build với `base` mặc định `/` → HTML của admin tham chiếu `/assets/...` → ALB đưa về **web-portal**. React Router cũng không có `basename`.
- **Hướng sửa:** `base: '/admin/'` trong `vite.config.ts` + `<BrowserRouter basename="/admin">`, hoặc tách host `admin.dev...`.
- **Bài:** [11](11-frontend-react-vite.md), [13](13-kubernetes-kustomize.md)

#### 🟡 B-07 — Script mất quyền thực thi; nguy cơ CRLF trên Windows
- **Bằng chứng:** commit `f8f310c` đổi mode `100755 → 100644` cho `scripts/*.sh`, `deploy/*/01-*.sh`. Máy bạn có `core.autocrlf=true` và repo **không có** `.gitattributes` → lần checkout sau, `.sh` có thể thành CRLF → container báo `$'\r': command not found`.
- **Hướng sửa:** `git update-index --chmod=+x <file>`; thêm `.gitattributes` với `*.sh text eol=lf` (và `* text=auto`). Tốt nhất: làm việc trong **WSL2**.
- **Bài:** [17](17-makefile-scripts-repo.md)

#### 🟡 B-08 — Vài điểm lệch nhỏ ở local stack
- `PERSISTENCE: "1"` của LocalStack là tính năng bản Pro (bản community bỏ qua); compose mount `/var/run/docker.sock` vào LocalStack (không cần cho dự án, lại là rủi ro bảo mật); biến `POSTGRES_MULTIPLE_DATABASES` được khai báo nhưng script không dùng (danh sách DB viết cứng); Redis có trong compose nhưng không service nào dùng.
- **Bài:** [12](12-docker-va-local-dev.md)

#### 🟠 B-09 — Integration test có thể chưa từng chạy
- **Bằng chứng:** 4 file test đều tên `*IT.java`; plugin surefire (pha `test`) mặc định chỉ chạy `*Test/*Tests/*TestCase/Test*`; không pom nào kích hoạt `maven-failsafe-plugin` (plugin chạy `*IT`). → `mvn verify` trong CI có thể xanh mà **0 test**. (Cần xác nhận khi chạy — Lab 10.1.)
- **Vì sao quan trọng:** "CI xanh" vô nghĩa nếu không chạy test. Luôn đọc số `Tests run` trong log, đừng chỉ nhìn dấu tích xanh.
- **Hướng sửa:** thêm `maven-failsafe-plugin` vào `<build><plugins>` của từng service.
- **Bài:** [10](10-backend-java-spring.md)

### 4.2 Logic backend (B-10 → B-19)

#### 🟠 B-10 — Billing có thể **mất hóa đơn vĩnh viễn** (`@Transactional` không có tác dụng)
- **Bằng chứng:** [OrderEventListener.java:64,76-77](../apps/backend/billing-service/src/main/java/com/bss/billing/listener/OrderEventListener.java): `poll()` gọi `handle(msg)` **trong cùng class** → Spring AOP proxy bị bỏ qua → annotation `@Transactional` trên `handle` vô hiệu. Kết quả: `saveDedupKey` (dòng 98-105) commit **ngay** trong transaction riêng của repository; nếu `invoiceFromOrder` sau đó lỗi, message ở lại hàng đợi, lần giao lại **bị coi là trùng** → bỏ qua + ACK → **không bao giờ có hóa đơn**.
- **Vì sao quan trọng:** đây là lỗi kinh điển số 1 của Spring ("self-invocation"). Nó phá đúng cái pattern mà code định bảo vệ. Bài học: annotation không phải phép màu — hiểu cơ chế proxy.
- **Hướng sửa:** tách `handle` sang một bean khác (vd. `OrderCompletedHandler`) với method `public @Transactional`. **Viết test tái hiện trước** (ép `invoiceFromOrder` ném lỗi lần 1, giao lại lần 2 → phải có hóa đơn).
- **Bài:** [10](10-backend-java-spring.md)

#### 🟠 B-11 — Khóa chống trùng sai → có thể xuất **2 hóa đơn cho 1 đơn**
- **Bằng chứng:** dedup theo `envelope.id` = ID do EventBridge sinh cho **mỗi lần** `PutEvents` ([OrderEventListener.java:81](../apps/backend/billing-service/src/main/java/com/bss/billing/listener/OrderEventListener.java)). Nếu outbox publish cùng một dòng 2 lần (xem B-12, hoặc PutEvents thành công nhưng UPDATE `published_at` rollback), billing nhận 2 event **khác id** → 2 hóa đơn.
- **Hướng sửa:** thêm `eventId` = id dòng outbox vào payload và dedup theo nó; hoặc thêm ràng buộc unique `invoice_item(source_order_id)` làm lưới an toàn thứ 2.
- **Bài:** [10](10-backend-java-spring.md)

#### 🟠 B-12 — Outbox drainer không an toàn khi chạy ≥ 2 replica
- **Bằng chứng:** [OrderEventPublisher.java:43-73](../apps/backend/order-management/src/main/java/com/bss/order/event/OrderEventPublisher.java) + query `findUnpublished` không khóa dòng → staging (2 replica) và prod (3 replica) **cùng đọc cùng dòng, cùng publish**. Ngoài ra lời gọi mạng `putEvents` nằm **bên trong** transaction DB (giữ connection trong lúc chờ mạng).
- **Hướng sửa:** `SELECT ... FOR UPDATE SKIP LOCKED` (native query), hoặc ShedLock/leader election.
- **Bài:** [10](10-backend-java-spring.md)

#### 🟠 B-13 — Giá tiền do **client** quyết định
- **Bằng chứng:** [CreateOrderRequest.java](../apps/backend/order-management/src/main/java/com/bss/order/dto/CreateOrderRequest.java) nhận `unitPrice` từ request; [OrderService.java:45-52](../apps/backend/order-management/src/main/java/com/bss/order/service/OrderService.java) dùng thẳng. Không kiểm tra customer có tồn tại, offering có tồn tại/đang bán. Ai gọi API cũng mua gói 199.000đ với giá 1đ.
- **Hướng sửa:** order-management gọi product-catalog (REST, có timeout + retry + circuit breaker Resilience4j) để lấy giá; kiểm tra customer.
- **Bài:** [10](10-backend-java-spring.md)

#### 🟡 B-14 — Test sinh lỗi ngầm
- `@MockBean EventBridgeClient` trả `null` cho `putEvents` → job outbox chạy mỗi 2s trong test ném `NullPointerException` (log ồn, che lỗi thật). Tương tự `SqsClient` mock trong billing. Test `X-Total-Count` so sánh **chuỗi** (`greaterThanOrEqualTo("4")` — "10" < "4" theo thứ tự chữ).
- **Hướng sửa:** tắt scheduling trong test (profile), stub mock trả response rỗng; so sánh số.

#### 🟡 B-15 — Lệch so với quy ước trong CLAUDE.md §7
- PK là **UUID v4** (`GenerationType.UUID`) chứ không phải v7; không có `Idempotency-Key` cho POST; `bss-common-java` không được dùng (4 bản sao exception handler); `customer-service` dùng **entity làm body API** (các service khác dùng DTO); phân trang `offset/limit` bị quy đổi sai khi `offset` không chia hết `limit` (vd. `offset=10&limit=20` trả bản ghi 0–19); PATCH "merge-patch" nhưng `null` nghĩa là "giữ nguyên" (RFC 7396 nói `null` = xóa trường).

#### 🟡 B-16 — Metric thiếu histogram và thiếu nhãn `application`
- Micrometer mặc định **không** xuất `http_server_requests_seconds_bucket` → panel p95 và alert latency luôn trống. Thiếu `management.metrics.distribution.percentiles-histogram.http.server.requests: true`.
- Chỉ `customer-service` có `management.metrics.tags.application`; 3 service còn lại không có → dashboard (lọc `application=~"$application"`) và alert `sum by (application)` không phân biệt được service.
- **Bài:** [16](16-platform-addons-observability.md)

#### 🟡 B-17 — Log/Shutdown chưa đúng như mô tả
- Log dạng text chứ không phải JSON, không có `trace_id`; K8s đặt `SPRING_PROFILES_ACTIVE=aws` nhưng không có `application-aws.yml`; có `server.shutdown: graceful` nhưng chưa có `spring.lifecycle.timeout-per-shutdown-phase` và `preStop` (ALB cần vài giây để ngừng gửi traffic).

#### 🔴 B-19 — Trên EKS, order/billing sẽ không lấy được quyền AWS qua IRSA
- **Bằng chứng:** [order-management/pom.xml](../apps/backend/order-management/pom.xml) và [billing-service/pom.xml](../apps/backend/billing-service/pom.xml) chỉ có module `eventbridge` / `sqs` của AWS SDK v2, **không có module `sts`**. `DefaultCredentialsProvider` dùng `WebIdentityTokenFileCredentialsProvider` cho IRSA — provider này **bắt buộc** module `sts` trên classpath. Thiếu nó, SDK bỏ qua IRSA và rơi xuống quyền của node (hoặc không có quyền nào) → `AccessDenied` khi PutEvents/ReceiveMessage. LocalStack không phát hiện được lỗi này vì dùng credential tĩnh `test/test`.
- **Vì sao quan trọng:** bài học "môi trường giả lập không bắt được lỗi danh tính". Phải có ít nhất một bài test thật trên AWS.
- **Hướng sửa:** thêm dependency `software.amazon.awssdk:sts` (version do BOM quản lý).
- **Bài:** [10](10-backend-java-spring.md), [14](14-terraform-aws.md)

#### 🟡 B-18 — Không có xác thực ở bất kỳ đâu
- Gateway không kiểm token; admin-console ai vào cũng **xóa được khách hàng**. 🔁 Đồ án bạn có JWT + bcrypt — ở đây là việc tương lai (Cognito/Keycloak + Spring Security resource server).

### 4.3 Kubernetes (B-20 → B-25)

#### 🔴 B-20 — 4 Secret DB được tham chiếu nhưng không ai tạo
- **Bằng chứng:** các Deployment dùng `secretKeyRef` tới `customer-db-credentials`, `product-db-credentials`, `order-db-credentials`, `billing-db-credentials`. Kết quả `kubectl kustomize overlays/dev` có **0** object `Secret`. [customer-secrets-spc.yaml](../platform/secrets/customer-secrets-spc.yaml) chỉ là mẫu cho 1 service, không nằm trong Kustomize, và Deployment **không mount** volume CSI (CSI chỉ sync ra K8s Secret khi có Pod mount) → Pod kẹt `CreateContainerConfigError`.
- **Bài:** [13](13-kubernetes-kustomize.md), [16](16-platform-addons-observability.md)

#### 🔴 B-21 — RDS chỉ có database `bss`; không có DB/user cho từng service
- **Bằng chứng:** [rds/variables.tf:21-24](../infrastructure/terraform/modules/rds/variables.tf) `initial_database_name = "bss"`; overlay trỏ `.../customer`, `/product`, `/orders`, `/billing`. Ở local có `postgres-init` tạo 4 DB, trên AWS **không có bước tương đương**. Ngoài ra mọi service dùng chung **tài khoản master** (vi phạm least privilege).
- **Hướng sửa:** K8s Job "db-bootstrap" (hoặc Terraform provider `postgresql`) tạo 4 DB + 4 user + GRANT; mỗi service một secret riêng.
- **Bài:** [13](13-kubernetes-kustomize.md), [14](14-terraform-aws.md)

#### 🟠 B-22 — Dev đặt 1 replica nhưng HPA ép lên 2 → thiếu tài nguyên
- **Bằng chứng:** overlay dev `replicas: 1`, nhưng HPA base `minReplicas: 2` (đã kiểm tra trên output kustomize: 7 HPA đều `minReplicas: 2`). → 14 pod app. Mỗi backend xin 512Mi; 2 node `t3.medium` (~3.3 GiB allocatable/node, **tối đa 17 pod/node** do giới hạn ENI) còn phải chứa hàng chục pod hệ thống + addon → Pod `Pending`.
- **Hướng sửa:** patch HPA `minReplicas: 1` ở dev; tính "ngân sách pod" (bài 13).

#### 🟠 B-23 — Ingress bật HTTPS nhưng không có certificate
- **Bằng chứng:** [ingress.yaml:12-13](../infrastructure/kubernetes/base/ingress.yaml) listen HTTPS 443 + ssl-redirect, không có `certificate-arn`; host là `dev.bss.example.com` (domain không thuộc về bạn) → ALB Controller không tìm được cert trong ACM → **không tạo ALB**.
- **Hướng sửa:** dev chỉ HTTP (patch annotation) cho đến khi có domain + ACM; dùng `spec.ingressClassName: alb`.

#### 🟡 B-24 — Cú pháp cũ & placeholder
- `commonLabels` đã deprecated (và **thêm label vào selector** — đổi về sau sẽ lỗi vì selector bất biến) → dùng `labels:`; annotation `kubernetes.io/ingress.class` đã cũ; IRSA annotation cho `product-catalog` trỏ role không tồn tại; DB host placeholder `bss-dev-rds...` trong khi RDS thật tên `bss-dev-pg`; mọi `CHANGE_ME`.

#### 🟡 B-25 — Chưa có NetworkPolicy, Pod Security Standards, ServiceMonitor
- Đúng như CLAUDE.md để dành Phase 9, nhưng ServiceMonitor là cần **ngay** khi cài Prometheus (B-40).

### 4.4 Terraform & AWS (B-30 → B-39)

#### 🔴 B-30 — `terraform init` thất bại ở cả 3 môi trường
- **Bằng chứng (đã chạy):** `Error: Function calls not allowed` tại [eventbridge/variables.tf:12](../infrastructure/terraform/modules/eventbridge/variables.tf) — `default` của variable **không được gọi hàm** (`jsonencode`).
- **Vì sao quan trọng:** chứng minh Terraform **chưa từng chạy**. Bài học: luôn `init/validate` trước khi tin bất kỳ IaC nào.
- **Hướng sửa:** viết JSON dạng chuỗi trong default, hoặc đưa `jsonencode(...)` vào `locals`/lời gọi module.
- **Bài:** [14](14-terraform-aws.md)

#### 🔴 B-31 — `terraform validate` thất bại (sau khi vá B-30)
- **Bằng chứng (đã chạy):** `element types must all match for conversion to list` — [iam/variables.tf:18](../infrastructure/terraform/modules/iam/variables.tf) khai báo `inline_policy_statements = list(any)`, nhưng [dev/main.tf:167](../infrastructure/terraform/environments/dev/main.tf) có `Resource = <string>` trong khi statement khác có `Resource = [<list>]` → kiểu không đồng nhất.
- **Hướng sửa:** luôn dùng list cho `Resource`, hoặc đổi kiểu thành `any`. (Tôi đã thử cả hai bản vá trên bản sao: `validate` pass cho dev/staging/prod.)

#### 🔴 B-32 — Mạng dev "không NAT, dùng VPC Endpoint" sẽ không chạy — và còn **đắt hơn**
- **Bằng chứng:** [dev/main.tf:67](../infrastructure/terraform/environments/dev/main.tf) `enable_nat_gateway = false`; node nằm private subnet; [vpc/main.tf:166](../infrastructure/terraform/modules/vpc/main.tf) chỉ có endpoint `ecr.api, ecr.dkr, secretsmanager, logs, sts` (+ S3). Thiếu `ec2` (VPC CNI cần để cấp IP cho Pod), `elasticloadbalancing` (ALB Controller), `sqs` (billing), `events` (order), `ssm`, `xray`... Và các addon Helm kéo image từ `quay.io`, `registry.k8s.io`, `public.ecr.aws`, Docker Hub → **không có Internet** → `ImagePullBackOff`.
- **💰 Chi phí (giá tham khảo ap-southeast-1, hãy tự kiểm tra trang pricing):** Interface endpoint ≈ $0.013/giờ **× mỗi AZ**. 5 endpoint × 2 AZ ≈ $0.13/giờ ≈ **$3.1/ngày**; bộ đầy đủ ~12 endpoint ≈ $7.5/ngày. Một NAT Gateway ≈ $0.059/giờ ≈ **$1.4/ngày** (+ phí dữ liệu). → Nhận định "VPC Endpoint rẻ hơn NAT" trong CLAUDE.md **sai với dev 2 AZ**.
- **Hướng sửa (⚖️ quyết định kiến trúc — viết ADR):** dev dùng **1 NAT** + chỉ giữ S3 Gateway endpoint (miễn phí); hoặc rẻ nhất: node ở public subnet có Security Group chặt (chỉ cho dev học tập).
- **Bài:** [14](14-terraform-aws.md)

#### 🔴 B-33 — Tài nguyên dùng chung bị đặt trong state từng môi trường
- **Bằng chứng:** module `ecr` với `name_prefix = "bss"` được gọi ở **cả 3** env → 3 state cùng muốn tạo `bss/customer-service`... → env thứ 2 lỗi "already exists". Dev (destroy mỗi tối) sở hữu repo dùng chung → hoặc xóa luôn image của staging/prod, hoặc destroy lỗi vì repo còn image (không có `force_delete`). GitHub OIDC provider + deployer role **chỉ** ở dev ([dev/main.tf:195](../infrastructure/terraform/environments/dev/main.tf)) → mất mỗi tối; staging/prod **không có role deployer nào**; secret `AWS_PROD_DEPLOYER_ROLE_ARN` trỏ tới role không tồn tại.
- **Hướng sửa:** tạo `environments/shared` (hoặc `global`) chứa ECR, GitHub OIDC provider, deployer roles; các env đọc qua `terraform_remote_state` hoặc biến.

#### 🔴 B-34 — Role deployer của GitHub không vào được cluster
- **Bằng chứng:** [iam/main.tf:107-140](../infrastructure/terraform/modules/iam/main.tf) role chỉ có quyền ECR + `eks:DescribeCluster`. Không có `aws_eks_access_entry` nào → `kubectl apply` trong CD bị `Unauthorized` (quyền IAM để *mô tả* cluster ≠ quyền Kubernetes RBAC bên trong cluster).
- **Hướng sửa:** `aws_eks_access_entry` + `aws_eks_access_policy_association` (giới hạn namespace `bss`).

#### 🔴 B-35 — Không có IAM cho các addon platform
- **Bằng chứng:** Terraform chỉ tạo IRSA cho customer/order/billing. Không có role cho **AWS LB Controller, ExternalDNS, Karpenter (+ hàng đợi interruption), EBS CSI, Fluent Bit, OTel/X-Ray**. [platform/README.md](../platform/README.md) gọi `terraform output aws_lb_controller_role_arn` — output **không tồn tại**. Comment đầu [eks/main.tf](../infrastructure/terraform/modules/eks/main.tf) nói "module này tạo IAM role cho Karpenter" nhưng không có.
- **Hướng sửa:** thêm module `platform-iam` (dùng IRSA hoặc **EKS Pod Identity** — cách mới đơn giản hơn), output ARN cho từng addon.

#### 🟠 B-36 — Phiên bản đã cũ
- `k8s_version = "1.30"` (các env) — 1.30 ra 5/2024, đã hết standard support từ 2025; nếu còn extended support thì phí control plane **$0.60/giờ thay vì $0.10** (gấp 6), nhiều khả năng đến 9/2026 không còn tạo mới được. RDS `engine_version = "15.5"` — minor cũ, AWS thường không cho tạo mới minor đã deprecated.
- **Hướng sửa:** kiểm tra `aws eks describe-cluster-versions`, `aws rds describe-db-engine-versions --engine postgres`; dùng bản mới nhất được hỗ trợ; ghim version provider.

#### 🟠 B-37 — Chu trình "apply sáng – destroy tối" sẽ gãy
- Secret Manager (`aws_secretsmanager_secret.db_master`) không có `recovery_window_in_days = 0` → sau destroy, tên secret bị "giữ" 7–30 ngày → apply hôm sau lỗi trùng tên.
- ECR không có `force_delete = true` → destroy lỗi khi còn image.
- ALB (do ALB Controller tạo), node Karpenter, ENI **không nằm trong state Terraform** → destroy VPC bị treo `DependencyViolation`. [teardown.sh](../scripts/teardown.sh) không xóa Ingress/NodePool trước.
- **Hướng sửa:** thêm các thuộc tính trên; teardown: `kubectl delete ingress --all -A`, xóa NodePool, chờ, rồi mới `terraform destroy`; viết script dọn "tài nguyên mồ côi" (gợi ý Python boto3 — bài 02).

#### 🟠 B-38 — Remote state chưa sẵn sàng
- Tên bucket `bss-platform-tfstate` ([bootstrap-aws.sh:18](../scripts/bootstrap-aws.sh)) là **tên toàn cầu** — gần như chắc đã có người dùng → đổi thành `bss-tfstate-<account_id>`. Block `backend "s3"` đang comment. Job plan trong CI dùng state local + thiếu biến bắt buộc `owner_email` → luôn lỗi. (Terraform ≥ 1.10 hỗ trợ `use_lockfile = true` trên S3, không cần DynamoDB nữa — một lựa chọn đơn giản hơn.)

#### 🟡 B-39 — Chất lượng/chi phí khác
- `terraform fmt -check` báo **6 file** sai format (đã chạy); tfsec sẽ báo nhiều mục; prod ghi "NAT HA" nhưng module chỉ tạo 1 NAT; RDS `log_statement = all` ghi **mọi câu SQL** ra CloudWatch (tốn tiền + có thể lộ PII); EKS bật cả 5 loại control-plane log ở dev (tốn tiền); trust policy GitHub `repo:<repo>:*` quá rộng (mọi nhánh/PR đều assume được); addon EBS CSI không có IAM → PVC không cấp được (liên quan B-41).

### 4.5 Platform & Observability (B-40 → B-43)

#### 🟠 B-40 — Prometheus sẽ **không scrape** ứng dụng nào
- **Bằng chứng:** Deployment dùng annotation `prometheus.io/scrape: "true"` — **kube-prometheus-stack (Prometheus Operator) bỏ qua annotation này**, nó chỉ đọc CRD `ServiceMonitor`/`PodMonitor`. Repo không có cái nào → dashboard trống, alert `BssServiceDown` (dựa trên `up{namespace="bss"}`) không bao giờ bắn.
- 🔁 Đồ án bạn dùng Prometheus "thường" với `kubernetes_sd_configs` + relabel theo annotation — cách đó đúng với cấu hình của bạn, nhưng không áp dụng cho Operator. Đây là điểm nối kiến thức rất đáng học.
- **Bài:** [16](16-platform-addons-observability.md)

#### 🟠 B-41 — PVC của Prometheus/Grafana/Alertmanager sẽ `Pending`
- `storageClassName: gp3` — EKS không tạo sẵn StorageClass `gp3`; và EBS CSI thiếu IAM (B-39).

#### 🟡 B-42 — Các addon khác
- Grafana `adminPassword: CHANGE_ME` nằm trong git; Alertmanager receiver rỗng (alert không đi đâu); Fluent Bit dùng parser `docker` trong khi EKS dùng containerd (định dạng **CRI**) → parse sai; OTel Collector không có ai gửi trace (service chưa gắn Java agent) và không có IAM X-Ray; lệnh cài Karpenter `helm repo add karpenter oci://...` **sai cú pháp** (OCI registry không `repo add` được) và thiếu value bắt buộc (`settings.clusterName`, role); Secrets CSI provider cài từ URL nhánh `main` (không ghim phiên bản).

#### 🟠 B-43 — Không cài `metrics-server` → HPA không hoạt động
- **Bằng chứng:** 7 HPA dùng metric `cpu`/`memory` (resource metrics) — cần **metrics-server**. [platform/README.md](../platform/README.md) liệt kê 7 addon nhưng không có metrics-server, và EKS không cài sẵn. HPA sẽ hiện `<unknown>/70%` và không bao giờ scale.
- 🔁 **Đồ án của bạn làm đúng chỗ này**: stage Deploy kiểm tra "prerequisites (Ingress Controller, metrics-server)" trước khi apply. Hãy mang thói quen "preflight check" đó sang dự án.
- **Hướng sửa:** thêm metrics-server (Helm chart hoặc EKS add-on) vào bước cài platform; CD kiểm tra tồn tại trước khi deploy.

### 4.6 CI/CD (B-50 → B-54)

#### 🔴 B-50 — CD dev không lưu "phiên bản nào đang chạy" → mỗi lần deploy phá các service khác
- **Bằng chứng:** [cd-dev.yml:96-105](../.github/workflows/cd-dev.yml): `kustomize edit set image` chỉ sửa file **trong runner** (không commit), rồi `kubectl apply -k` **cả overlay**. Service không đổi trong commit này bị apply lại với image `CHANGE_ME...:dev` (giá trị trong git) → `ImagePullBackOff`.
- **Vì sao quan trọng:** đây là câu hỏi cốt lõi của CD: *"Nguồn sự thật (source of truth) về phiên bản đang chạy nằm ở đâu?"* Đồ án của bạn tránh được vì build **tất cả** image mỗi lần.
- **Hướng sửa (⚖️ viết ADR):** (a) bot commit overlay trở lại repo (GitOps-lite); (b) ArgoCD đọc overlay từ git (GitOps chuẩn); (c) chỉ `kubectl set image` cho service thay đổi; (d) build lại mọi service mỗi lần merge.
- **Bài:** [15](15-cicd-github-actions.md)

#### 🔴 B-51 — "Build once, deploy many" gãy khi build theo path-filter
- **Bằng chứng:** cd-dev chỉ build service **thay đổi** với tag = SHA commit đó. [cd-staging.yml:38-60](../.github/workflows/cd-staging.yml) re-tag image của **SHA mà tag trỏ tới** → service không đổi ở commit đó **không có image** → bị `skip`, nhưng bước sau vẫn set `:rc-vX` cho **cả 7** → `ImagePullBackOff`.
- **Hướng sửa:** một "release manifest" ghi SHA đang chạy của từng service (gắn với B-50); promotion đọc manifest đó.

#### 🟠 B-52 — Smoke test không bao giờ thất bại → rollback tự động không bao giờ chạy
- **Bằng chứng:** [cd-dev.yml:117](../.github/workflows/cd-dev.yml) `... || true`; [smoke.sh:23,27](../scripts/smoke.sh) `|| echo "failed"` → exit 0. Và `/api/actuator/health` qua gateway **không có route** → luôn 404.
- **Hướng sửa:** smoke gọi endpoint nghiệp vụ thật (`/api/tmf-api/productCatalog/v4/productOffering`), fail = exit ≠ 0, rollback khi fail.

#### 🟠 B-53 — Mọi workflow CI (trừ k8s) sẽ đỏ
- Tổng hợp: backend (B-01), frontend (B-04), terraform (fmt 6 file, tfsec, thiếu biến, backend chưa bật — B-38). Ngoài ra sửa `packages/bss-common-java/**` kích hoạt workflow nhưng path-filter không map vào service nào → không build gì.

#### 🟡 B-54 — Vệ sinh pipeline
- `cd-dev` không có `concurrency` (2 lần merge đua nhau); action ghim theo tag chứ không theo commit SHA (rủi ro chuỗi cung ứng — sự cố `tj-actions/changed-files` tháng 3/2025 là bài học); `ECR_REGISTRY` để trong secrets (không phải bí mật → dùng `vars`, lại bị che trong log gây khó debug); re-tag bằng `docker pull/push` (chậm) thay vì `aws ecr put-image` với manifest; rollback prod từng deployment → có thể còn lẫn phiên bản; tfsec đã được gộp vào Trivy (`trivy config`).

### 4.7 Tài liệu (B-60)

#### 🟡 B-60 — Tài liệu lệch thực tế
- `docs/ROADMAP.md` là bản GCP/GKE cũ; CLAUDE.md §13 và badge README "Phase 1 complete" lạc quan; `api-contracts/README.md` nhắc `PaymentReceived.schema.json` không tồn tại; `platform/README.md` nói Makefile gói `platform-install` (thật ra chỉ `echo`); course nhắc `apps/backend/pom.xml` parent và "logging filter trong bss-common-java" — không tồn tại; Vite chạy port **3000** (course ghi 5173); ước tính chi phí dev ~$5/ngày thấp hơn thực tế (xem bài 14 mục chi phí).

---

## 5. Tổng hợp theo mức độ

| Mức | Số lượng | Mã |
|---|---|---|
| 🔴 P0 — chặn | 13 | B-01, B-02, B-19, B-20, B-21, B-30, B-31, B-32, B-33, B-34, B-35, B-50, B-51 |
| 🟠 P1 — sai/nguy hiểm | 18 | B-03, B-04, B-05, B-09, B-10, B-11, B-12, B-13, B-22, B-23, B-36, B-37, B-38, B-40, B-41, B-43, B-52, B-53 |
| 🟡 P2 — chất lượng | còn lại | B-06, B-07, B-08, B-14..B-18, B-24, B-25, B-39, B-42, B-54, B-60 |

Thứ tự sửa **không** theo mức độ mà theo **giai đoạn** của lộ trình (sửa cái cần cho bước đang làm) — xem [20](20-lo-trinh-hoan-thanh.md).

---

## 6. Cách dùng danh sách này

1. Mỗi lỗi → **1 GitHub Issue** (tiêu đề `B-10: billing @Transactional self-invocation`), gắn label `P0/P1/P2` + khu vực.
2. Mỗi lần sửa → **1 nhánh** `fix/b10-billing-tx` → PR tham chiếu issue → merge.
3. Lỗi logic (B-10..B-13) → **viết test tái hiện (đỏ) trước, rồi sửa (xanh)** — đúng quy ước CLAUDE.md mục 9.
4. Khi sửa xong, cập nhật cột trạng thái ở bảng mục 2 và ghi một dòng vào [nhật ký](nhat-ky-hoc-tap.md).

❓ Tự kiểm tra: *Chọn 3 lỗi P0 bất kỳ, giải thích cho một người không biết code vì sao nó chặn cả dự án.*

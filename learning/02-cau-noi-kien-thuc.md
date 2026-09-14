# 02 — Cầu nối kiến thức: Đồ án OSM + DevOps Bootcamp ↔ BSS Platform

> Mục tiêu bài: dùng những gì bạn **đã biết** làm "móc treo" cho kiến thức mới — nhớ lâu hơn nhiều so với học từ số 0.
> Đồng thời ôn lại kiến thức cũ qua ví dụ mới, và xác định những gì **nên bổ sung** vào dự án.

Nguồn đối chiếu:
- Slide đồ án tốt nghiệp *"Online Service Marketplace — Microservices + CI/CD on AWS"* (Nguyễn Đức Mạnh, GVHD TS. Tạ Quang Ngọc).
- 16 handout DevOps Bootcamp (TechWorld with Nana) ở `D:\DevOps\02. DevOps Bootcamp 2024-12\PDF\Handout`.

---

## 1. So sánh chi tiết theo từng lớp

Cột cuối — **"Mang gì từ đồ án sang"** — là những thói quen tốt bạn đã có mà dự án này đang thiếu.

| Lớp | Đồ án OSM của bạn | BSS Platform | Vì sao khác (trade-off) | Mang gì từ đồ án sang |
|---|---|---|---|---|
| Backend | Node.js 22 + Express, 4 service port 4001–4004 | Java 21 + Spring Boot 3.2, 4 service + gateway, port 8080 | Telco VN dùng Java nhiều; Spring có hệ sinh thái transaction/JPA/Actuator mạnh. Đổi lại: image nặng hơn (JVM), khởi động chậm hơn (cần startupProbe) | — |
| Xác thực | JWT middleware, bcrypt, express-validator | **Chưa có** (B-18); chỉ Bean Validation | Scaffold để dành | **JWT + validation** — bạn đã làm được |
| Frontend | Vue 3 + Vite | React 18 + Vite + TanStack Query | Thị trường React lớn hơn; khái niệm tương đương (bài 11) | — |
| Gateway | Nginx reverse proxy (image `osm-gateway`) | Spring Cloud Gateway (Java) | Gateway viết bằng code → dễ thêm auth, rate-limit, circuit breaker; đổi lại nặng hơn Nginx | — |
| Database | MongoDB **1 EC2 private**, cài bằng Ansible | RDS PostgreSQL managed, Flyway migration | Managed = backup/patch/multi-AZ do AWS lo; SQL + ACID phù hợp tiền bạc/hóa đơn | Script **backup ra S3** (RDS có automated backup, nhưng lab restore vẫn cần) |
| Test | Jest + MongoMemoryServer | JUnit 5 + Testcontainers (Postgres thật) | Testcontainers sát production hơn DB giả; đổi lại cần Docker khi test | Test **nhánh lỗi** ("service unreachable", "DB error") — đồ án bạn có, dự án thiếu |
| Giao tiếp | HTTP đồng bộ order → user/payment | HTTP + **EventBridge → SQS** bất đồng bộ | Tách phụ thuộc, retry tự nhiên; đổi lại eventual consistency + phải idempotent | — |
| Container | `node:22-alpine`, `nginx:alpine` | `eclipse-temurin:21-jre-jammy`, Nginx non-root | JRE trên Ubuntu jammy tương thích glibc tốt; alpine nhỏ hơn | — |
| Registry | ECR, 6 repo | ECR, 7 repo, **IMMUTABLE** + lifecycle + scan on push | Immutable chống ghi đè tag | — |
| Tag image | main: `:1.0.3` + `:latest`; dev: `:dev-42-a1b2c3f` | `:<git-sha>` → `:rc-vX` → `:vX` | `latest` là mutable → không biết chắc đang chạy gì; tag dev của bạn đã immutable — rất tốt | Ý tưởng **gắn build number + SHA** |
| IaC | Terraform 1.10, 5 module (vpc/iam/ecr/eks/ec2), NAT Gateway | Terraform, 7 module, 3 môi trường, không NAT ở dev | Tách môi trường thành thư mục; thêm rds/eventbridge/observability | Thiết kế **có NAT** của bạn chạy được; bản dev không NAT ở đây thì không (B-32) |
| Cấu hình server | **Ansible** 3 role (common/mongodb/jenkins), jump host | Không có | Không còn server "nuôi": node EKS là managed + bất biến; DB là RDS | Xem đề xuất mục 5 |
| CI/CD | **Jenkins** trên EC2, 12 stage, multibranch, webhook | **GitHub Actions** 7 workflow, path-filter, tag promotion | Không phải vận hành server Jenkins; OIDC không cần credential; đổi lại phụ thuộc GitHub | **Verify rollout + kiểm tra prerequisites** (B-43), **auto version bump** |
| Xác thực CI→AWS | IAM Role gắn EC2 Jenkins (không lưu key) | GitHub OIDC → AssumeRoleWithWebIdentity | Cùng triết lý "không có key tĩnh", khác cơ chế | — |
| Môi trường | nhánh `main`/`dev`/`refactor/*` + namespace `osm`/`osm-dev` trong 1 cluster | tag + 3 cluster riêng | Cô lập mạnh hơn nhưng đắt ×3 | Namespace-per-env **rẻ** — gợi ý cho giai đoạn học (bài 20) |
| Entry | NGINX Ingress Controller + NLB | AWS Load Balancer Controller → ALB | ALB là managed, tích hợp WAF/ACM; Ingress-NGINX đang bị Kubernetes cho "nghỉ hưu" (mục 7) | — |
| Scale | HPA CPU>70%/Mem>80%, 2→5; đề xuất Cluster Autoscaler | HPA + Karpenter (spot) | Karpenter chọn loại máy linh hoạt, gom node nhanh | **metrics-server** (dự án quên — B-43) |
| Secret | K8s Secret (`osm-secrets`); đề xuất Secrets Manager | Secrets Manager + Secrets Store CSI | K8s Secret chỉ base64; Secrets Manager có audit, rotation | — |
| Monitoring | Prometheus + annotations `prometheus.io/scrape`, `prom-client`, Grafana LoadBalancer :3000 | kube-prometheus-stack (Operator) + Micrometer, Grafana ClusterIP | Operator quản lý bằng CRD (ServiceMonitor) | ⚠️ annotation **không** chạy với Operator (B-40) |
| Log / Trace | — | Fluent Bit → CloudWatch; OTel → X-Ray | "3 trụ cột" observability | — |
| Automation | Python boto3: health_check, backup_mongodb, cleanup_ecr | Không có (ECR lifecycle thay cleanup_ecr) | — | **Bộ script vận hành** (mục 5.1) |
| Load test | Đề xuất k6/Locust | Course nhắc k6/vegeta | — | Máy bạn **đã cài k6** |

---

## 2. Jenkins 12 stage của bạn ↔ GitHub Actions trong dự án

| # | Stage đồ án | Tương đương trong BSS | Ghi chú |
|---|---|---|---|
| 1 | Skip CI Check (`[skip ci]`, chown file) | GitHub tự bỏ qua workflow khi commit message có `[skip ci]`; `paths:` filter | Runner GitHub là máy **dùng một lần** → không có file root sót lại |
| 2 | Init: `aws sts get-caller-identity` → Account ID | `aws-actions/configure-aws-credentials` + OIDC; `ECR_REGISTRY` | Có thể tính registry từ `aws sts` như bạn làm thay vì lưu secret |
| 3 | Checkout | `actions/checkout@v4` | — |
| 4 | Validate (refactor/*) | `ci-terraform.yml`, `ci-k8s.yml` chạy trên PR | Dự án validate trên **mọi PR**, không cần nhánh riêng |
| 5 | Read version từ `package.json` | Version = **git tag** (`rc-v0.1.0`, `v0.1.0`) | `pom.xml` có `<version>0.1.0</version>` nhưng chưa dùng |
| 6 | Run tests trong `node:22-slim` | `mvn -B verify` (Testcontainers) | — |
| 7 | Build 6 image, 2 tag/1 tag | `docker build -t .../bss/<svc>:<sha>` | Chỉ service thay đổi (path-filter) → gây B-51 |
| 8 | Push ECR (instance role) | Push ECR (OIDC role) | — |
| 9 | Cleanup Docker | Không cần (runner tạm) + ECR lifecycle | — |
| 10 | Deploy: update-kubeconfig, kiểm prerequisites, `kubectl apply` | update-kubeconfig, `kubectl apply -k` | Thiếu kiểm prerequisites; thiếu access entry (B-34) |
| 11 | Verify: `rollout status` 120s | `rollout status --timeout=5m` + `rollout undo` | Tương đương, dự án thêm rollback |
| 12 | Bump version + commit `[skip ci]` | Không cần — tag là version | Nhưng **chính ý tưởng "commit trở lại repo"** là lời giải cho B-50 |

Khái niệm Jenkins ↔ GitHub Actions:

| Jenkins (handout 8) | GitHub Actions |
|---|---|
| Jenkinsfile (declarative) | `.github/workflows/*.yml` |
| `agent` | `runs-on: ubuntu-latest` |
| `stages/stage/steps` | `jobs/<job>/steps` (job chạy song song, `needs:` để nối tiếp) |
| `post { always/success/failure }` | `if: always()`, `if: failure()` |
| `parameters` | `workflow_dispatch.inputs` |
| Multibranch pipeline | `on: push/pull_request/tags` với bộ lọc |
| Credentials (secret text, username/password) | `secrets.*`, `vars.*`, **Environments** (secret + người duyệt riêng) |
| `input` step (duyệt tay) | `environment: production` + Required reviewers |
| Shared Library | **Reusable workflow** (`workflow_call`) / composite action — 3 file CD đang lặp code, đây là bài tập tốt |
| Plugin | Action trên Marketplace (`uses: org/action@ref`) |
| Webhook GitHub → Jenkins | Có sẵn — GitHub tự kích hoạt |

---

## 3. Bản đồ 16 module Bootcamp → dự án (kèm ôn nhanh)

### Module 1 — Intro to DevOps
- **Trong dự án:** toàn bộ vòng đời: code → test → build → push → deploy → monitor. CLAUDE.md mục 5 là "DevOps process" của dự án.
- 🔁 Ôn: CI/CD = TEST → BUILD → PUSH → DEPLOY; mục tiêu "release nhanh và ít lỗi".

### Module 2 — Linux
- **Trong dự án:** script bash ([scripts/](../scripts/)): `set -euo pipefail`, heredoc, `read`; **user/UID/GID** (container non-root: `useradd --system`, `runAsUser: 1000`); **quyền file** (`chmod +x` — B-07); biến môi trường (`DB_URL`, `.env`); networking (CIDR `10.10.0.0/16`, DNS `svc.bss.svc.cluster.local`, port 8080/5432/4566).
- 🔁 Ôn: "đừng làm việc bằng root" (handout 5) chính là `runAsNonRoot: true` trong K8s. `AmazonSSMManagedInstanceCore` trên node = vào máy bằng **SSM Session Manager** thay cho SSH (không mở port 22).

### Module 3 — Git
- **Trong dự án:** trunk-based (`main` luôn deploy được), **tag** kích hoạt staging/prod, Conventional Commits ([CONTRIBUTING.md](../CONTRIBUTING.md)), PR template, `.gitignore` cho secret.
- 🔁 Ôn: "không push thẳng main" → bật **branch protection** + bắt CI xanh. Mới: `.gitattributes` (line ending), `git update-index --chmod=+x`.

### Module 4 — Build Tools & Package Manager
- **Trong dự án:** Maven (`pom.xml`, `spring-boot-starter-parent`, lifecycle `validate → compile → test → package → verify`, output `target/*.jar`), npm (`package.json`, `npm ci` cần lockfile — B-04).
- 🔁 Ôn: artifact JAR; "Docker image là artifact thay cho mọi loại artifact" — đúng như dự án.

### Module 5 — Cloud Basics & IaaS
- **Trong dự án:** node EKS là EC2; bảo mật: user riêng cho từng ứng dụng → mỗi service một **ServiceAccount + IAM Role** riêng.

### Module 6 — Nexus (Artifact Repository)
- **Trong dự án:** ECR đóng vai "artifact repository" cho image. **Chưa có** repo cho artifact Maven (`bss-common-java`) và npm (`ui-kit`) → đó là lý do 2 package này không được dùng (B-15). Cleanup policy của Nexus ↔ **ECR lifecycle policy**.
- Đề xuất ở mục 5.6.

### Module 7 — Docker
- **Trong dự án:** multi-stage build, non-root, `docker-compose` (Postgres/Redis/LocalStack), **named volume** `postgres-data` (handout: "named volume nên dùng cho production"), private registry ECR (`registry/image:tag`).
- 🔁 Checklist best practice của handout ↔ dự án: official image ✅ · version cụ thể 🟡 (`postgres:15-alpine` chưa ghim patch) · minimal base 🟡 · layer cache ✅ (`COPY pom.xml` trước) · `.dockerignore` ❌ · multi-stage ✅ · least-privileged user ✅ · scan ✅ (Trivy trong CI) · không nhét secret vào image ✅.

### Module 8 — Jenkins
- Được thay bằng GitHub Actions (mục 2). Kiến thức pipeline-as-code, versioning, webhook dùng lại nguyên vẹn.

### Module 9 — AWS
- **Trong dự án:** IAM (user cho người, **role** cho service — handout: "policy không gắn trực tiếp cho service, dùng role"), Region/AZ (`ap-southeast-1`, 2–3 AZ), VPC/subnet public-private/IGW/NAT/Security Group, EC2, AWS CLI.
- 🔁 Security Group tham chiếu Security Group: [rds/main.tf:42-48](../infrastructure/terraform/modules/rds/main.tf) chỉ cho phép port 5432 **từ SG của node EKS** — thay vì mở theo CIDR.

### Module 10 — Kubernetes
- **Trong dự án:** Pod/Deployment/Service/ConfigMap/Secret/Ingress/Namespace/HPA/PDB/ServiceAccount; **Helm** (platform addons); **Operator** (Prometheus Operator); **RBAC + ServiceAccount**; best practices handout (pinned version, liveness/readiness, requests/limits, không NodePort, >1 replica, >1 node, label, namespace, non-root, scan) — dự án làm gần như đủ.
- Không dùng: StatefulSet cho DB (dùng RDS). Nhưng khi chạy local bằng kind (giai đoạn 2), bạn sẽ viết **StatefulSet Postgres + PVC** — đúng bài handout.

### Module 11 — Kubernetes on AWS (EKS)
- **Trong dự án:** EKS + **Managed Node Group** (handout: "semi-managed") + Karpenter; IAM role cluster/node; ECR pull bằng node role (`AmazonEC2ContainerRegistryReadOnly`).
- 🔁 Handout: Jenkins deploy EKS bằng **IAM user riêng + aws-iam-authenticator + kubeconfig** → dự án: **OIDC role + `aws eks update-kubeconfig` + access entry** (cơ chế mới, không còn file credential).
- 🔁 Handout nhắc **Cluster Autoscaler** → dự án dùng **Karpenter** (so sánh ở bài 16). Handout best practice "KMS envelope encryption cho Secret" → dự án chưa bật (`encryption_config`) — đề xuất nhỏ.

### Module 12 — Terraform
- **Trong dự án:** provider, resource, data source (`aws_availability_zones`, `aws_caller_identity`), variable/output, module, remote state S3 + lock, "1 state mỗi môi trường", CI cho Terraform.
- 🔁 Handout: "provisioner không khuyến khích" → dự án không dùng ✅. "Không hardcode, dùng data source" → dự án dùng `data.aws_partition` ✅. "Apply chỉ qua CD pipeline" → dự án vẫn apply tay (hợp lý khi học).

### Module 13 — Programming (Python) & Module 14 — Automation (boto3)
- **Trong dự án:** không có Python. Handout: "Terraform cho provisioning, Python cho tác vụ vận hành" → đề xuất bộ script ở mục 5.1.

### Module 15 — Ansible
- Không có. Phân tích "có nên thêm không" ở mục 5.7.

### Module 16 — Prometheus
- **Trong dự án:** kube-prometheus-stack (handout: "cách 3 — Helm + Operator"), node-exporter DaemonSet, kube-state-metrics, Grafana, Alertmanager, PrometheusRule, **client library** = Micrometer (Java) — tương đương `prom-client` (Node) bạn đã dùng.
- 🔁 Handout bước "Deploy **ServiceMonitor** (custom K8s resource) để báo Prometheus về exporter/app mới" — **chính là mảnh ghép dự án đang thiếu** (B-40). Handout có sẵn ví dụ redis-exporter → áp dụng: postgres metrics qua CloudWatch/YACE hoặc postgres-exporter.

### Bonus — Databases
- **Trong dự án:** relational Postgres (ACID — cần cho hóa đơn: "hoặc tất cả, hoặc không gì cả" chính là transaction outbox), key-value Redis (có trong compose, chưa dùng → cache), cấu hình DB **từ bên ngoài qua biến môi trường theo từng môi trường** (handout slide "Configure DB connection 4.1 — Spring properties file") ↔ `${DB_URL:...}` trong `application.yml`, replication (RDS multi-AZ prod), backup (retention 1/7/30 ngày).

---

## 4. Đổi mới tư duy: 5 điều bạn cần "học lại"

1. **Từ "server" sang "không có server để nuôi".** Đồ án: Ansible cấu hình EC2 Jenkins/Mongo. Dự án: mọi thứ chạy là **Pod bất biến** hoặc **dịch vụ managed**. Muốn đổi → build image mới, không SSH vào sửa.
2. **Từ credential sang identity.** IAM user/key → **role tạm thời qua OIDC** (cả GitHub lẫn Pod). Câu hỏi luôn là "*ai* đang gọi và trust policy có tin *ai* đó không".
3. **Từ đồng bộ sang bất đồng bộ.** Chấp nhận dữ liệu trễ vài giây; mọi consumer phải chịu được message trùng.
4. **Từ "deploy xong là xong" sang "nguồn sự thật".** Phiên bản đang chạy phải được ghi lại ở đâu đó (git) — bài học B-50.
5. **Từ "chạy được" sang "chứng minh được".** `init/validate/plan`, test tái hiện lỗi, smoke test **biết fail**. Đồ án của bạn đã có tinh thần này (verify rollout, test suite chặn deploy).

---

## 5. Những gì Bootcamp/đồ án có mà dự án CHƯA có — đề xuất bổ sung

Mỗi đề xuất: **Là gì · Giúp gì · Đặt ở đâu · Học thế nào · Ưu tiên · Trade-off**.

### 5.1 Bộ script vận hành Python boto3 — ⭐ Ưu tiên CAO

- **Là gì:** thư mục `tools/ops/` với các script nhỏ, có test (pytest + `moto` để giả lập AWS).
- **Giúp gì:** giải quyết đúng các vấn đề của dự án:
  - `orphan_finder.py` — sau `terraform destroy`, liệt kê ALB/Target Group/ENI/EIP/EBS/NAT còn sót theo tag `Project=bss-platform` (giải B-37; tránh "hóa đơn ma").
  - `cost_report.py` — Cost Explorer theo tag `Environment`, in chi phí 7 ngày (FinOps — handout 14 "cluster information").
  - `dlq_tool.py` — xem/redrive message trong DLQ `bss-*-billing-orders-dlq` (runbook thật cho alarm DLQ).
  - `preflight.py` — trước khi apply: đúng account? đúng region? bucket state tồn tại? budget đã bật? (giống stage Init của bạn).
  - `health_check.py` — port từ đồ án: gọi các endpoint nghiệp vụ + kiểm tra deployment Ready; exit 0/1 để CD dùng làm smoke test (giải B-52).
- **Học thế nào:** ôn handout 13–14; viết từng script một, mỗi script có `--dry-run`.
- ⚖️ Trade-off: không dùng Python để **tạo** hạ tầng (đã có Terraform — handout 14 "Terraform vs Python"), chỉ dùng cho tác vụ vận hành/kiểm tra.

### 5.2 Load test với k6 — ⭐ CAO (hướng tương lai trong slide của bạn)

- **Đặt ở:** `tests/load/plans-and-order.js`: 70% GET gói cước, 30% POST đơn hàng; `thresholds` p95 < 500ms, error < 1%.
- **Giúp gì:** lab HPA/Karpenter (course bài 14) cần tải thật; trả lời câu hỏi "hệ thống chịu bao nhiêu req/s" mà slide 10c của bạn đặt ra.
- **Học:** k6 đã cài sẵn trên máy bạn (`C:\Program Files\k6`).

### 5.3 Alerting ra Slack/Discord/Email — ⭐ CAO (hướng tương lai trong slide)

- **Đặt ở:** Alertmanager config (qua Secret, không để webhook URL trong git) + `runbook_url` trỏ `docs/runbooks/*.md`.
- **Học:** handout 16 phần Alertmanager (receiver, route, grouping).

### 5.4 Xác thực JWT — CAO về tính "thật" của sản phẩm

- **Là gì:** Keycloak (local, thêm vào docker-compose) hoặc Amazon Cognito; Spring Security **OAuth2 Resource Server** ở gateway; admin-console yêu cầu role `admin`.
- 🔁 Bạn đã làm JWT + bcrypt bằng Express — khác biệt: ở đây **không tự phát token** mà dùng Identity Provider chuẩn OIDC (lại là OIDC!).

### 5.5 Redis cache cho product-catalog — TRUNG BÌNH

- **Là gì:** Spring Cache + Redis cho `GET productOffering` (đọc nhiều, ít đổi); dùng Redis cho `RequestRateLimiter` của gateway.
- 🔁 Handout Databases: "key-value — best for caching"; slide 10c mức 3 của bạn đề xuất đúng việc này.
- ⚖️ Thêm một thành phần phải vận hành (ElastiCache tốn tiền) → chỉ làm ở local/kind trước.

### 5.6 Artifact repository cho thư viện dùng chung (tinh thần Nexus) — TRUNG BÌNH

- **Là gì:** publish `bss-common-java` lên **GitHub Packages** (miễn phí) hoặc AWS CodeArtifact; các service khai báo dependency thay vì chép code.
- **Giúp gì:** xóa 4 bản sao exception handler (B-15). Đây đúng là bài toán handout 6 giải: "một nơi trung tâm chứa artifact".
- ⚖️ Thư viện chung trong microservices tạo **coupling** (đổi lib → phải build lại mọi service). Giữ lib **nhỏ, ổn định**.

### 5.7 Ansible — THẤP–TRUNG BÌNH (có chủ đích)

Phân tích thẳng: kiến trúc EKS managed + RDS **không còn server nào cần cấu hình**, nên Ansible không có "chỗ tự nhiên" như ở đồ án. Nếu muốn giữ kỹ năng Ansible, có 2 vị trí hợp lý:
1. **Cài đặt platform addons bằng playbook** (module `kubernetes.core.helm`) thay cho danh sách lệnh tay trong [platform/README.md](../platform/README.md) — biến 7 lệnh helm thành 1 lệnh idempotent. ⚖️ Lựa chọn khác phổ biến hơn trong ngành: `helmfile`, Terraform `helm_release`, hoặc ArgoCD app-of-apps.
2. **Bastion / self-hosted GitHub runner** trên EC2 khi bạn khóa endpoint EKS prod về private — Ansible cấu hình máy đó (Docker, kubectl, aws-cli), đúng như role `jenkins` của bạn.

### 5.8 Jenkinsfile tương đương — THẤP–TRUNG BÌNH (giá trị thị trường)

- Nhiều công ty VN vẫn dùng Jenkins/GitLab CI. Viết `ci/Jenkinsfile` chạy cùng các bước của `ci-backend.yml` giúp bạn trả lời được câu "so sánh Jenkins và GitHub Actions" bằng kinh nghiệm thật. Chỉ làm sau khi GitHub Actions đã xanh.

### 5.9 Helm chart cho ứng dụng — TRUNG BÌNH

- Tạo `charts/bss-service` generic (1 template, 7 file values) để **so sánh** với Kustomize — handout 10 "Helm cho microservices: 1 template chung". ⚖️ Kustomize: không template, dễ đọc; Helm: tham số hóa mạnh, có versioning/rollback. Giữ Kustomize làm chính, Helm để học.

### 5.10 Backup & restore có kiểm chứng — TRUNG BÌNH

- 🔁 Kế thừa `backup_mongodb.py`. Với RDS: automated backup đã có; bổ sung **lab restore** (snapshot → instance mới → kiểm tra dữ liệu) và snapshot tay trước khi destroy môi trường có dữ liệu cần giữ. "Backup chưa từng restore = chưa có backup."

### 5.11 GitOps với ArgoCD — TRUNG BÌNH (sau khi CD cơ bản chạy)

- Lời giải "chuẩn ngành" cho B-50/B-51: git là nguồn sự thật, ArgoCD kéo về cluster. CLAUDE.md để dành — hợp lý; chỉ làm khi đã hiểu vì sao cần.

### 5.12 AI cho DevOps — THẤP (hướng tương lai trong slide)

- Bạn đang dùng Claude Code — hãy dùng có phương pháp: review PR, tóm tắt log lỗi CI, viết runbook nháp. Nguyên tắc: không dán secret/credential vào prompt; luôn kiểm chứng đầu ra (bài học từ chính repo này).

---

## 6. Kiến thức hoàn toàn mới — cần học từ đầu

| Chủ đề | Học ở đâu trong sổ tay | Tài liệu gốc nên đọc |
|---|---|---|
| Java 21 + Spring Boot (DI, JPA, Transaction, Actuator) | [10](10-backend-java-spring.md) | Spring Boot guide "Building a RESTful Web Service", "Accessing Data with JPA" |
| Spring AOP proxy & `@Transactional` | [10](10-backend-java-spring.md) mục B-10 | Spring docs "Understanding AOP Proxies" |
| Outbox / Idempotent consumer | [10](10-backend-java-spring.md) | microservices.io (Chris Richardson) |
| React + TanStack Query | [11](11-frontend-react-vite.md) | react.dev "Learn", TanStack Query docs |
| Kustomize | [13](13-kubernetes-kustomize.md) | kubectl.docs.kubernetes.io |
| IRSA / EKS Pod Identity / Access Entries | [14](14-terraform-aws.md) | EKS Best Practices Guide — Security |
| EventBridge + SQS | [14](14-terraform-aws.md), [10](10-backend-java-spring.md) | AWS docs |
| GitHub OIDC | [15](15-cicd-github-actions.md) | GitHub docs "Configuring OpenID Connect in AWS" |
| Prometheus Operator, OTel, Fluent Bit | [16](16-platform-addons-observability.md) | prometheus-operator.dev, opentelemetry.io |
| Karpenter | [16](16-platform-addons-observability.md) | karpenter.sh |

---

## 7. Cập nhật ngành liên quan tới kiến thức cũ của bạn (tính đến 2026)

> Ngành thay đổi nhanh; các mục dưới đây là những thay đổi quan trọng mà handout 2024 chưa có. Hãy **tự kiểm chứng** trên trang chính thức trước khi áp dụng.

| Bạn đã học | Thay đổi | Ảnh hưởng tới dự án |
|---|---|---|
| NGINX Ingress Controller (đồ án) | Kubernetes SIG Network thông báo (cuối 2025) cho **Ingress-NGINX nghỉ hưu**, chỉ bảo trì tối thiểu đến khoảng 3/2026 | Hướng đi là **Gateway API** hoặc controller của cloud (ALB). Dùng ingress-nginx cho kind local vẫn ổn để học |
| IRSA (handout chưa có) | **EKS Pod Identity** (2023) — không cần OIDC provider riêng, cấu hình đơn giản hơn | Cân nhắc cho addon mới (B-35) |
| aws-auth ConfigMap | **EKS Access Entries** (API) thay cho `aws-auth` | Dùng cho deployer role (B-34) |
| tfsec | Đã gộp vào **Trivy** (`trivy config`) | Đổi bước trong `ci-terraform.yml` |
| S3 + DynamoDB lock | Terraform ≥ 1.10 hỗ trợ khóa bằng file trên S3 (`use_lockfile`) | Có thể bỏ DynamoDB (B-38) |
| Cluster Autoscaler | **Karpenter v1** ổn định (2024) | Dùng CRD `karpenter.sh/v1` như repo |
| Amazon Linux 2 | EKS chuyển mặc định sang **AL2023**; AL2 không hỗ trợ cho Kubernetes mới | Node group dùng AMI mặc định là ổn khi nâng version |
| AWS Free Tier 12 tháng | Từ 7/2025, tài khoản mới dùng mô hình **credit** (Free plan có thời hạn) | Đọc kỹ điều khoản khi tạo account; EKS control plane chưa bao giờ free |
| Kustomize `commonLabels` | Deprecated → `labels:` | B-24 |

---

## 8. Checkpoint bài 02

- [ ] Giải thích được 3 khác biệt lớn nhất giữa đồ án và dự án, mỗi cái kèm trade-off.
- [ ] Ánh xạ được 12 stage Jenkins sang workflow của dự án không cần nhìn bảng.
- [ ] Chọn **2 đề xuất** ở mục 5 bạn muốn làm, ghi vào [nhật ký](nhat-ky-hoc-tap.md) kèm lý do.
- [ ] Trả lời: *"Vì sao annotation `prometheus.io/scrape` chạy trong đồ án của tôi mà không chạy ở đây?"*

# 12 — Docker & môi trường local (docker-compose + LocalStack)

> Mục tiêu bài: hiểu từng dòng Dockerfile và docker-compose, sửa B-01/B-02/B-05/B-07/B-08, và dựng được
> **toàn bộ hệ thống chạy trên laptop, không tốn một đồng AWS**. Thời lượng: 3h đọc + 6–8h lab. **Giai đoạn 1.**

---

## 0. Trước hết: chọn môi trường làm việc trên Windows

Máy bạn: Windows 10, Git Bash, **không có `make`**, `core.autocrlf=true`, JDK/Maven chưa cài. Khuyến nghị mạnh:

| Lựa chọn | ⚖️ |
|---|---|
| **WSL2 + Ubuntu** (khuyến nghị) | Giống hệt runner CI (Linux): có `make`, bash, quyền thực thi file, line ending LF; Docker Desktop tích hợp WSL. Clone repo **vào filesystem Linux** (`~/code/bss-platform`), không để trong `/mnt/c` (chậm, lỗi quyền) |
| Git Bash + `choco install make` | Nhanh, nhưng vẫn gặp CRLF, quyền file, khác biệt đường dẫn |
| PowerShell thuần | Không chạy được Makefile/script bash |

Cài trong WSL2: `openjdk-21-jdk`, `maven`, `nodejs 20`, `kubectl`, `kind`, `helm`, `terraform`, `awscli`, `jq`, `yq`, `trivy`. Docker Desktop → Settings → Resources → WSL integration → bật cho Ubuntu.

🔁 Handout Linux: "Linux là bắt buộc cho DevOps" — WSL2 là cách có Linux thật mà không cần máy ảo nặng.

---

## 1. Ôn nhanh Docker (từ handout 7) bằng ví dụ dự án

| Khái niệm handout | Trong dự án |
|---|---|
| Image vs container | `bss/customer-service:<sha>` là image; Pod trên K8s chạy container từ image đó |
| Layer & cache | Mỗi lệnh `RUN/COPY` = 1 layer; `COPY pom.xml` **trước** `COPY src/` → đổi code không phải tải lại dependency |
| Multi-stage | Stage `build` có JDK + Maven (~500MB+), stage runtime chỉ JRE + JAR (~250MB) |
| Private registry | `<account>.dkr.ecr.ap-southeast-1.amazonaws.com/bss/<service>:<tag>` |
| Volume | `postgres-data` (named volume) giữ dữ liệu Postgres khi `docker compose down` |
| docker-compose tạo network chung | Container gọi nhau bằng tên service (`postgres`, `localstack`) |
| Best practice: least privileged user | `useradd --system bss` + `USER bss` |
| Best practice: scan | Trivy trong CI |

---

## 2. Dockerfile backend — đọc từng dòng (customer-service)

🔍 [customer-service/Dockerfile](../apps/backend/customer-service/Dockerfile)

```dockerfile
# syntax=docker/dockerfile:1.6            # bật cú pháp BuildKit mới (cần cho --mount=type=cache)
FROM eclipse-temurin:21-jdk-jammy AS build  # stage 1: JDK 21 trên Ubuntu 22.04 "jammy". ⚠️ KHÔNG có Maven
WORKDIR /workspace
COPY pom.xml .
COPY .mvn/ .mvn/                           # ⚠️ B-01: thư mục này không tồn tại trong repo → build dừng ở đây
COPY mvnw .                                # ⚠️ B-01: file này cũng không có
RUN --mount=type=cache,target=/root/.m2 \  # cache ~/.m2 giữa các lần build (không nằm trong image)
    ./mvnw dependency:go-offline -B        # tải trước dependency → layer riêng, tái dùng khi chỉ đổi code
COPY src/ src/
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B clean package -DskipTests    # đóng gói JAR; -B = batch (log gọn cho CI); bỏ test (CI đã chạy)

FROM eclipse-temurin:21-jre-jammy          # stage 2: chỉ JRE → nhỏ hơn, ít lỗ hổng hơn
RUN groupadd --system bss && useradd --system --gid bss bss   # user hệ thống (UID < 1000, tự cấp)
USER bss
WORKDIR /app
COPY --from=build /workspace/target/*.jar app.jar   # chỉ lấy artifact từ stage 1
EXPOSE 8080                                # tài liệu hóa port (không mở port thật)
ENTRYPOINT ["java",
  "-XX:MaxRAMPercentage=75.0",             # heap tối đa = 75% memory limit của container (cgroup)
  "-XX:+UseG1GC",                          # GC mặc định hợp lý cho server
  "-XX:+ExitOnOutOfMemoryError",           # hết heap → thoát ngay → K8s restart, thay vì "sống dở chết dở"
  "-jar", "/app/app.jar"]
```

4 Dockerfile còn lại gọi `mvn` (không phải `mvnw`) — nhưng image `eclipse-temurin` không có Maven → `mvn: not found`. Dòng đầu có `|| true` nên lỗi bị nuốt, dòng thứ hai mới vỡ.

**Hướng sửa gợi ý (bạn tự áp dụng và giải thích được từng dòng):**

```dockerfile
# syntax=docker/dockerfile:1.7
FROM maven:3.9-eclipse-temurin-21 AS build     # image có sẵn cả JDK 21 lẫn Maven
WORKDIR /workspace
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B -q dependency:go-offline
COPY src/ src/
RUN --mount=type=cache,target=/root/.m2 mvn -B -q package -DskipTests

FROM eclipse-temurin:21-jre-jammy
RUN groupadd --system --gid 10001 bss && useradd --system --uid 10001 --gid bss bss
USER 10001                                     # USER dạng SỐ → K8s kiểm được runAsNonRoot
WORKDIR /app
COPY --from=build /workspace/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java","-XX:MaxRAMPercentage=75.0","-XX:+UseG1GC","-XX:+ExitOnOutOfMemoryError","-jar","/app/app.jar"]
```

Và thêm `.dockerignore` cạnh Dockerfile:
```
target/
*.iml
.idea/
```

🧠 Vì sao `USER` nên là **số**? Kubelet kiểm `runAsNonRoot: true` bằng cách đọc UID của image. Với `USER bss` (tên), kubelet không biết `bss` có phải root không → phải dựa vào `runAsUser` trong manifest (dự án có đặt `runAsUser: 1000` nên vẫn chạy — nhưng khi đó container chạy UID 1000, **khác** UID của user `bss` trong image; file JAR đọc được vì quyền 644). Đặt UID số ở cả hai nơi cho nhất quán.

⚖️ Nhỏ hơn nữa: `jlink` tự tạo JRE tối giản, distroless `gcr.io/distroless/java21` (không có shell → khó debug, ít bề mặt tấn công), GraalVM native (khởi động mili-giây, build lâu, hạn chế reflection). Ghi lại kích thước từng lần thử (Lab 12.3).

---

## 3. docker-compose — đọc từng khối

🔍 [deploy/docker-compose.yml](../deploy/docker-compose.yml)

| Khối | Giải thích | Ghi chú |
|---|---|---|
| `postgres` | `postgres:15-alpine`, user/pass `bss/bss`, port 5432, volume `postgres-data`, mount `./postgres-init` vào `/docker-entrypoint-initdb.d` (chỉ đọc) | Script trong thư mục đó chạy **một lần** khi volume còn trống. Muốn chạy lại → `docker compose down -v` |
| `healthcheck: pg_isready` | Compose biết khi nào Postgres sẵn sàng | Service khác dùng `depends_on: condition: service_healthy` |
| `POSTGRES_MULTIPLE_DATABASES` | ⚠️ Không có tác dụng: script tự viết cứng danh sách DB (B-08) | Xóa hoặc cho script đọc biến này |
| `redis` | Redis 7, port 6379 | Chưa service nào dùng — chỗ để làm cache/rate-limit (bài 02 mục 5.5) |
| `localstack` | `localstack/localstack:3.4`, port 4566 duy nhất cho mọi dịch vụ, `SERVICES: s3,sqs,events,secretsmanager,iam,sts` | `PERSISTENCE` là tính năng Pro; mount `docker.sock` không cần (B-08) |
| `./localstack-init:/etc/localstack/init/ready.d` | Script chạy khi LocalStack **ready** | Cần file có quyền thực thi + line ending LF (B-07) |
| `adminer` | UI web xem DB tại http://localhost:8081 (server `postgres`, user `bss`) | Tiện khi lab outbox |

🔍 [postgres-init/01-create-databases.sh](../deploy/postgres-init/01-create-databases.sh)
- `set -e` → lỗi là dừng.
- Vòng `for db in customer product orders billing` → `psql <<-EOSQL ... EOSQL` (heredoc `<<-` cho phép thụt tab).
- `CREATE DATABASE $db; GRANT ALL PRIVILEGES ...` — user `bss` đã là owner nên GRANT thừa nhưng vô hại.

🔍 [localstack-init/01-bootstrap.sh](../deploy/localstack-init/01-bootstrap.sh)

| Dòng | Làm gì | Tương ứng trên AWS (Terraform) |
|---|---|---|
| 12 | `events create-event-bus bss-dev-events` | `aws_cloudwatch_event_bus` |
| 15–18 | tạo DLQ, lấy ARN | `aws_sqs_queue.dlq` |
| 20–21 | tạo queue chính với `RedrivePolicy` (JSON lồng trong JSON → escape `\\\"`), `maxReceiveCount: 5` | `aws_sqs_queue.main` + `redrive_policy` |
| 28–31 | `put-rule` với event pattern `source=bss.order`, `detail-type ∈ {OrderCompleted, OrderRefunded}` | `aws_cloudwatch_event_rule` |
| 33–36 | `put-targets` → queue | `aws_cloudwatch_event_target` |
| 39–41 | secret `bss-dev/rds/master` | `aws_secretsmanager_secret` (module rds) |

⚠️ Khác biệt LocalStack ↔ AWS thật cần biết: LocalStack **không kiểm quyền IAM** mặc định, không cần SQS queue policy cho EventBridge, credential `test/test` luôn đúng → lỗi IAM/IRSA (B-19, B-34) **chỉ lộ ra trên AWS**.

---

## 4. Chạy toàn bộ hệ thống ở local (sau khi sửa B-02)

Sơ đồ port đề xuất:

| Thành phần | Port | Profile/biến |
|---|---|---|
| customer-service | 8081 | `SPRING_PROFILES_ACTIVE=local`, DB `customer` |
| product-catalog | 8082 | DB `product` |
| order-management | 8083 | DB `orders`, `AWS_ENDPOINT_URL=http://localhost:4566` |
| billing-service | 8084 | DB `billing`, `SQS_QUEUE_URL=http://localhost:4566/000000000000/bss-dev-billing-orders` |
| api-gateway | 8080 | profile `local` → route tới `localhost:8081..8084` |
| web-portal / admin-console | 3000 / 3001 | Vite proxy `/api` → 8080 |
| Adminer | 8081 ⚠️ trùng customer → đổi Adminer sang 8090 | |

Ví dụ `application-local.yml` cho order-management (bạn tự viết cho 4 service kia):

```yaml
server:
  port: 8083
spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/orders
aws:
  endpoint-url: http://localhost:4566
```

Script end-to-end nên có (Lab 12.5 — `scripts/e2e-local.sh`): tạo customer → lấy offering Pro 80 → tạo order → chờ tối đa 30s đến khi `customerBill` có 1 hóa đơn → kiểm tra `taxAmount = 19900.00`. Script **exit ≠ 0 khi sai** (bài học B-52).

🔍 Soi luồng sự kiện bằng `awslocal` (cài `pip install awscli-local`):
```bash
awslocal events list-rules --event-bus-name bss-dev-events
awslocal sqs get-queue-attributes --queue-url http://localhost:4566/000000000000/bss-dev-billing-orders --attribute-names All
awslocal sqs receive-message --queue-url http://localhost:4566/000000000000/bss-dev-billing-orders-dlq
```
Và trong Adminer: `SELECT id, event_type, published_at FROM event_outbox ORDER BY created_at DESC;` (DB `orders`), `SELECT * FROM processed_event;` (DB `billing`).

---

## 5. Labs

| Lab | Nội dung | Lỗi | Đạt khi |
|---|---|---|---|
| 12.0 | Cài WSL2 + toolchain; clone repo vào `~/code`; thêm `.gitattributes`; `git update-index --chmod=+x` 5 script | B-07 | `make help` chạy trong WSL |
| 12.1 | Sửa 5 Dockerfile backend + `.dockerignore`; build cả 7 image | B-01 | `docker images` có 7 image |
| 12.2 | `trivy image --severity HIGH,CRITICAL` từng image; ghi bảng kết quả; xử lý CVE bằng nâng base image/dependency | — | 0 HIGH/CRITICAL hoặc có `.trivyignore` kèm lý do |
| 12.3 | So sánh kích thước: single-stage JDK / multi-stage JRE / distroless / jlink | — | Bảng số liệu trong nhật ký |
| 12.4 | `docker compose up -d`; kiểm LocalStack đã tạo bus/queue/rule; dọn compose (B-08) | B-08 | `docker compose ps` healthy |
| 12.5 | `application-local.yml` × 5 + `scripts/e2e-local.sh` | B-02 | Script in "PASS" và exit 0 |
| 12.6 | Thử nghiệm outbox: tắt LocalStack (`docker stop bss-localstack`), đặt 3 đơn, bật lại → hóa đơn vẫn đủ | — | 3 hóa đơn, không trùng |
| 12.7 | Thử nghiệm DLQ: gửi tay 1 message sai định dạng vào queue → sau 5 lần nhận nằm ở DLQ | — | Thấy message trong DLQ |

## 6. Tự kiểm tra

1. Vì sao `COPY pom.xml` trước `COPY src/` làm build nhanh hơn?
2. `--mount=type=cache` khác `COPY ~/.m2` vào image thế nào?
3. `-XX:MaxRAMPercentage=75` với memory limit 1Gi → heap tối đa bao nhiêu? 25% còn lại dùng cho gì?
4. Script trong `docker-entrypoint-initdb.d` chạy khi nào? Làm sao để nó chạy lại?
5. Nêu 2 loại lỗi mà LocalStack không thể phát hiện nhưng AWS thật sẽ báo.

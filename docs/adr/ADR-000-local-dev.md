# ADR-000 — Cách chạy local (port, profile, DB, AWS)

- **Trạng thái:** Chấp nhận (Accepted)
- **Ngày:** 2026-09-14
- **Giai đoạn:** 1 — Local chạy thật end-to-end

## Bối cảnh

Trước fix này, mọi service backend hardcode `server.port: 8080` trong `application.yml` — hợp lý
trên K8s (mỗi service một Pod, một network namespace riêng, không có xung đột port) nhưng vỡ
ngay khi chạy 5 service backend trực tiếp trên một laptop (`mvn spring-boot:run`, không qua
container/K8s): service thứ hai khởi động sau sẽ báo lỗi `Port 8080 already in use`. Gateway
cũng route tới DNS nội bộ K8s (`customer-service.bss.svc.cluster.local`) — tên miền này chỉ tồn
tại bên trong cluster, không resolve được từ laptop (B-02).

Cần một cách **tách cấu hình theo môi trường** mà không phá cấu hình K8s đang có.

## Quyết định

Dùng **Spring profile `local`** (`SPRING_PROFILES_ACTIVE=local`, đã có sẵn trong
`deploy/.env.example`) + file `application-local.yml` ở mỗi service. File này **chỉ** override
những gì thật sự khác nhau giữa "chạy trên laptop" và "chạy trên K8s": port và (với
api-gateway/order-management) địa chỉđích của service khác.

### Bảng cổng (port map) khi chạy local

| Service | Port | Ghi chú |
|---|---|---|
| api-gateway | 8080 | Không đổi — khớp target proxy `/api` của Vite (`vite.config.ts`) |
| customer-service | 8081 | |
| product-catalog | 8082 | |
| order-management | 8083 | Gọi product-catalog qua `http://localhost:8082` (xem B-13) |
| billing-service | 8084 | |

### Database & AWS endpoint

**Không** dùng profile cho phần này — dùng biến môi trường (`deploy/.env.example`), vì cùng một
giá trị áp dụng cho *cả* local lẫn (một phần) K8s:
- `DB_HOST`/`DB_PORT`/`DB_NAME`/`DB_USER`/`DB_PASSWORD` — mỗi service đã có default riêng đúng
  theo tên DB của nó (`customer`, `product`, `orders`, `billing`) ngay trong `application.yml`,
  không cần profile. (Giai đoạn 5/B-20: trước đây gộp hết vào 1 biến `DB_URL`; tách thành 3 biến
  để AWS có thể lấy `DB_HOST`/`DB_PORT` thẳng từ Secrets Manager thay vì phải sửa tay CHANGE_ME —
  xem ADR-004.)
- `AWS_ENDPOINT_URL=http://localhost:4566` — trỏ AWS SDK sang LocalStack; để trống (mặc định)
  khi chạy thật trên AWS thì `DefaultCredentialsProvider` tự dùng IRSA (xem `AwsConfig` của
  order-management/billing-service).

### Route rút gọn của gateway (B-03)

Gateway trước đây có 2 predicate cho mỗi route: bản đầy đủ TMF
(`/api/tmf-api/customerManagement/**`) và một bản "rút gọn" (`/api/customers/**`). Sau
`StripPrefix=1`, bản rút gọn trở thành `/customers/**` — path này **không tồn tại** ở bất kỳ
service nào (chỉ có `/tmf-api/customerManagement/v4/customer`). `grep` xác nhận cả web-portal
lẫn admin-console chỉ bao giờ gọi đường dẫn TMF đầy đủ. Quyết định: **xóa** predicate rút gọn
thay vì vá bằng `RewritePath` — giữ 1 route = 1 path thật, không để lại một "lối tắt" trông hợp
lý nhưng luôn 404.

## Hệ quả

- ✅ Chạy đủ 5 backend cùng lúc trên 1 laptop mà không cần Docker/K8s.
- ✅ `scripts/e2e-local.sh` có thể tự start/stop 5 service bằng `mvn spring-boot:run` và test
  luồng thật qua gateway.
- ⚠️ Có 2 nguồn cấu hình cho "chạy ở đâu" (profile `local` cho port/route, biến môi trường cho
  DB/AWS) — không gộp làm một để tránh phải sửa `application.yml` mỗi khi đổi biến môi trường
  runtime (vốn hợp với triết lý 12-factor: cấu hình môi trường qua env var, không qua code/profile).
- ⚠️ Trùng lặp: route local phải liệt kê lại *toàn bộ* danh sách route (Spring Boot thay thế
  nguyên list `List` property khi profile ghi đè, không merge từng phần tử) — chấp nhận được ở
  quy mô 4 route.

## Lựa chọn khác đã cân nhắc

1. **Docker Compose cho cả 5 backend** (không chỉ Postgres/LocalStack) — mô phỏng K8s sát hơn
   (mỗi service một network namespace, DNS thật). Không chọn cho Giai đoạn 1 vì mất vòng lặp
   "sửa code → thấy kết quả ngay" (phải rebuild image mỗi lần đổi code) — để dành cho
   Giai đoạn 2 (kind cluster).
2. **Một cổng dùng chung qua nhiều `.env` khác nhau** (mỗi service một file `.env`) — phức tạp
   hơn Spring profile sẵn có trong framework, không tận dụng được `SPRING_PROFILES_ACTIVE` mà
   `.env.example` đã khai báo sẵn.

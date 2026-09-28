# Runbook: xác thực (Keycloak + Spring Security ở gateway) — Giai đoạn 7, việc 6 (B-18)

## 1. Bức tranh chung

- **Keycloak** (chỉ overlay `local`/kind) — realm `bss`, 2 role (`admin`, `customer`), 2 user thử
  (`admin1`/`admin1pass`, `customer1`/`customer1pass`) — khai trong
  `infrastructure/kubernetes/overlays/local/keycloak/realm-bss.json`.
- **api-gateway** validate JWT (OAuth2 Resource Server). Luật phân quyền
  (`com.bss.gateway.config.SecurityConfig`):

  | Route | Yêu cầu |
  |---|---|
  | `/actuator/**` | Công khai |
  | Mọi `GET` | Công khai (duyệt gói cước, v.v.) |
  | `/api/tmf-api/customerManagement/**` (mọi method không phải GET) | Role `admin` |
  | Còn lại (đặt hàng, v.v.) | Đã đăng nhập (bất kỳ role) |

- **Bật/tắt theo overlay** qua property `bss.auth.enabled` (mặc định `false`) — CHỈ `local` bật
  (`BSS_AUTH_ENABLED=true` trong `overlays/local/kustomization.yaml`). dev/staging/prod **chưa**
  có Keycloak/Cognim thật → cố tình giữ tắt, tránh cd-dev tự phá chính nó (mọi request ghi sẽ
  401 nếu bật mà không có nơi phát hành token nào tồn tại).

## 2. Cài đặt (kind)

```bash
./scripts/auth-install.sh kind        # tạo Secret keycloak-admin (idempotent)
kubectl apply -k infrastructure/kubernetes/overlays/local
kubectl -n bss rollout status deploy/keycloak
```

Keycloak nằm dưới **path `/auth` của cùng host** `http://bss.localtest.me/auth` (Giai đoạn 9 việc
2, [ADR-008](../adr/ADR-008-danh-tinh-va-quyen-so-huu.md) quyết định 2). Giai đoạn 7 từng dùng
subdomain `auth.bss.localtest.me` với `KC_HOSTNAME` = DNS nội bộ cluster. Cách đó hỏng luồng đăng
nhập của trình duyệt, vì Keycloak chuyển hướng trình duyệt tới địa chỉ nội bộ mà trình duyệt không
mở được. Hiện tại:

| Giá trị | Ở đâu | Là gì |
|---|---|---|
| `KC_HOSTNAME=http://bss.localtest.me/auth` + `KC_HTTP_RELATIVE_PATH=/auth` | `overlays/local/keycloak/deployment.yaml` | `iss` trong token = địa chỉ công khai; 2 biến phải cùng mang `/auth` |
| `…JWT_ISSUER_URI=http://bss.localtest.me/auth/realms/bss` | `api-gateway-config` | Chỉ để **so khớp** `iss` |
| `…JWT_JWK_SET_URI=http://keycloak.bss.svc.cluster.local:8080/auth/realms/bss/protocol/openid-connect/certs` | `api-gateway-config` | Tải khóa qua DNS **nội bộ**. Có giá trị này thì Spring không gọi discovery, nên Pod không phải resolve `bss.localtest.me` (trong Pod tên đó trỏ 127.0.0.1) |

docker-compose (`deploy/`) chạy Keycloak ở `http://localhost:8180/auth`, **mount chung** file
`realm-bss.json` với kind.

## 3. Lấy token thật + gọi thử API

```bash
ADMIN_TOK=$(curl -s -X POST http://bss.localtest.me/auth/realms/bss/protocol/openid-connect/token \
  -d grant_type=password -d client_id=api-gateway -d username=admin1 -d password=admin1pass \
  | sed -E 's/.*"access_token":"([^"]+)".*/\1/')

CUST_TOK=$(curl -s -X POST http://bss.localtest.me/auth/realms/bss/protocol/openid-connect/token \
  -d grant_type=password -d client_id=api-gateway -d username=customer1 -d password=customer1pass \
  | sed -E 's/.*"access_token":"([^"]+)".*/\1/')

curl -s http://bss.localtest.me/api/tmf-api/productCatalog/v4/productOffering                     # 200, không cần token
curl -s -X POST http://bss.localtest.me/api/tmf-api/orderManagement/v4/productOrder -d '{}'       # 401, thiếu token
curl -s -X DELETE http://bss.localtest.me/api/tmf-api/customerManagement/v4/customer/<id> \
  -H "Authorization: Bearer $CUST_TOK"                                                            # 403, role customer không đủ
curl -s -X DELETE http://bss.localtest.me/api/tmf-api/customerManagement/v4/customer/<id> \
  -H "Authorization: Bearer $ADMIN_TOK"                                                           # 404 (không tìm thấy id giả) — QUA được security
```

**Kết quả đã tự chạy thật (Giai đoạn 7 việc 6):**

| Kịch bản | Kỳ vọng | Kết quả thật |
|---|---|---|
| GET public, không token | 200 | ✅ 200 |
| POST order, không token | 401 | ✅ 401 |
| POST customer, role `customer` | 403 | ✅ 403 |
| DELETE customer, role `customer` | 403 | ✅ 403 |
| POST customer, role `admin` | qua security (400 nghiệp vụ ở customer-service) | ✅ 400 (không phải 401/403) |
| DELETE customer, role `admin` | qua security (404 — id giả) | ✅ 404 (không phải 401/403) |
| POST order, role `customer` (đã đăng nhập) | qua security (422 nghiệp vụ) | ✅ 422 `customerId: must not be null` |

Đây chính là checkpoint Giai đoạn 7: **"gọi API không token → 401" — ĐẠT**, và fix đúng B-18
("admin-console ai vào cũng xóa được khách hàng" — giờ cần role `admin` thật).

## 4. Bug thật gặp khi dựng (đọc trước khi tự làm lại, đỡ mất thời gian)

| Triệu chứng | Nguyên nhân | Sửa |
|---|---|---|
| `Account is not fully set up` khi xin token | Keycloak realm mặc định bật `VERIFY_PROFILE` — kiểm tra động lúc đăng nhập, không đọc `requiredActions` của user | `requiredActions` cấp REALM đặt `VERIFY_EMAIL`/`VERIFY_PROFILE` = `enabled: false` (không đủ chỉ set `emailVerified: true` ở user) |
| Keycloak Pod CrashLoop, log `ReadOnlyFileSystemException` | `start-dev --import-realm` build Quarkus JIT lúc khởi động, ghi vào `/opt/keycloak/lib/...` — xung đột `readOnlyRootFilesystem: true` | `readOnlyRootFilesystem: false` riêng cho Keycloak (dev-mode only — production dùng `kc.sh build` lúc build image, không cần ghi gì lúc chạy) |
| Readiness/liveness probe 404 dù Pod healthy | Keycloak 26.x phục vụ `/health/*` trên PORT QUẢN TRỊ RIÊNG (9000), không phải 8080 | Probe trỏ port 9000 |
| Gọi `.../auth/realms/bss/...` → `Unable to find matching target resource method` | nginx Ingress không tự cắt path prefix; Keycloak không hiểu `/auth` nếu chưa cấu hình | GĐ7 né bằng subdomain. GĐ9 sửa gốc: đặt **cả** `KC_HTTP_RELATIVE_PATH=/auth` lẫn `KC_HOSTNAME=…/auth` (xem mục 2) |
| Trình duyệt bị chuyển hướng tới `keycloak.bss.svc.cluster.local` và không mở được trang đăng nhập (GĐ9) | `KC_HOSTNAME` = DNS nội bộ cluster. Chỉ `curl` + password grant mới không lộ lỗi này | `KC_HOSTNAME` = địa chỉ công khai; service tải JWKS qua `jwk-set-uri` nội bộ (ADR-008) |
| *(phòng ngừa, chưa tự tái hiện)* Health probe có thể 404 sau khi thêm `KC_HTTP_RELATIVE_PATH=/auth` | Theo tài liệu Keycloak 26, cổng quản trị 9000 **thừa kế** relative path nếu không đặt riêng → `/auth/health/ready` | Đặt thêm `KC_HTTP_MANAGEMENT_RELATIVE_PATH=/` (đã làm; probe `/health/*` chạy xanh) |
| Gateway trả 500 khi CÓ token (không phải 401 sạch) | issuer-uri cấu hình sai đường (có `/auth` trong khi `iss` thật của token không có) → Spring không tải được JWKS | issuer-uri phải khớp CHÍNH XÁC domain/path Keycloak thật sự lắng nghe |
| `hasRole("admin")` luôn từ chối dù token có role thật | Keycloak để role trong `realm_access.roles` (JSON lồng), không phải claim `scope` phẳng mà `JwtAuthenticationConverter` mặc định đọc | `JwtGrantedAuthoritiesConverter` tùy biến đọc `realm_access.roles`, thêm tiền tố `ROLE_` |

## 5. Còn lại (ngoài phạm vi PR này)

- **AWS Cognito hoặc Keycloak Terraform-hóa cho dev/staging/prod** — chưa làm, cần tài khoản AWS
  thật, hỏi trước khi tạo tài nguyên (CLAUDE.md §9).
- **Frontend (web-portal/admin-console) chưa có màn hình đăng nhập** — B-18 tập trung vào backend
  (gateway thật sự kiểm token, đã xong + kiểm chứng). Muốn thao tác qua UI thật cần thêm form
  đăng nhập gọi `/realms/bss/protocol/openid-connect/token` (grant `password`, đơn giản cho nội
  bộ — KHÔNG phải chuẩn cho SPA hướng người dùng cuối thật, nơi nên dùng Authorization Code +
  PKCE) rồi lưu token, đính `Authorization: Bearer` vào mọi request qua axios interceptor. Cho tới
  lúc đó, `curl`/Postman với token thủ công (xem mục 3) là cách kiểm tra.
- **order-management chỉ cần "đã đăng nhập"**, chưa phân biệt "khách hàng chỉ xem đơn/hóa đơn của
  chính mình" (cần so khớp `sub` trong token với `customerId` — việc riêng, sâu hơn khuôn khổ B-18).

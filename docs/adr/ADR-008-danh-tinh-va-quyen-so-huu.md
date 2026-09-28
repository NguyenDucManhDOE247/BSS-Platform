# ADR-008 — Mô hình danh tính & quyền sở hữu dữ liệu cho 2 website

- **Trạng thái:** Đề xuất (Proposed) — chờ chủ repo đọc và xác nhận
- **Ngày:** 2026-09-28
- **Giai đoạn:** 9 — Sản phẩm hoàn chỉnh (việc 1)

## Bối cảnh

Giai đoạn 7 (việc 6, B-18) mới làm xác thực ở **phía backend**: api-gateway kiểm JWT của Keycloak,
và chỉ trên kind. Rà soát ngày 2026-09-28 cho thấy 2 website vẫn chưa dùng thật được:

1. **web-portal không có danh tính người dùng.** Mọi người vào web đều là 1 khách cố định
   `DEMO_CUSTOMER_ID`. Khách này không tồn tại trong customer-service, và order-management không
   kiểm tra khách có tồn tại. Kết quả: đơn và hóa đơn gắn vào "khách ma" mà admin không bao giờ thấy.
2. **Không có quy tắc sở hữu.** Ai biết `customerId` của người khác thì xem được hóa đơn của người đó
   (`GET /customerBill?customerId=...` chỉ cần đăng nhập).
3. **Keycloak trên kind không hỗ trợ được đăng nhập bằng trình duyệt.** `KC_HOSTNAME` đang là
   `http://keycloak.bss.svc.cluster.local:8080`. Đó là DNS nội bộ cluster, được chọn vì gateway (chạy
   trong cluster) cần khớp `iss`. Nhưng với luồng đăng nhập của trình duyệt, Keycloak sẽ chuyển hướng
   người dùng tới chính địa chỉ này, mà trình duyệt thì không truy cập được. Bài runbook auth chỉ
   kiểm bằng `curl` + password grant nên chưa lộ ra.
4. **Frontend không có dòng code xác thực nào**, và dev/staging/prod trên AWS **chưa có
   Keycloak**. Gateway ở đó mở hoàn toàn (`bss.auth.enabled=false`), nên B-18 chưa đóng trên AWS.

ADR này chốt 6 quyết định liên quan với nhau. Code của Giai đoạn 9 (việc 2–7) làm theo đúng các
quyết định này.

## Quyết định 1 — Luồng đăng nhập cho 2 SPA: Authorization Code + PKCE

| # | Phương án | Ưu | Nhược |
|---|---|---|---|
| A | Form đăng nhập tự viết + **password grant** (cách runbook auth gợi ý) | Nhanh, không chuyển trang | SPA **cầm mật khẩu người dùng**; password grant đã bị loại khỏi OAuth 2.1; không có đăng ký/quên mật khẩu sẵn |
| B | **Authorization Code + PKCE**, chuyển sang trang đăng nhập của Keycloak | Chuẩn hiện hành cho SPA (RFC 7636, OAuth 2.1); SPA không bao giờ thấy mật khẩu; có sẵn đăng ký, quên mật khẩu, khóa tài khoản | Thêm 1 thư viện OIDC ở frontend; cần cấu hình redirect URI đúng cho từng môi trường |
| C | Backend-for-Frontend (BFF): token nằm ở server, trình duyệt chỉ có cookie | An toàn nhất trước XSS | Thêm 1 thành phần server mới cho mỗi SPA, lệch trọng tâm "không over-engineer" |

**Chọn B.** Dùng thư viện `oidc-client-ts` + `react-oidc-context` (chuẩn OIDC chung, không khóa chặt
vào Keycloak). Token lưu ở `sessionStorage`, là mặc định của thư viện và mất khi đóng tab.
⚠️ Đánh đổi: token ở `sessionStorage` vẫn đọc được nếu trang bị XSS. C (BFF) là hướng nâng cấp khi
cần, ghi lại ở đây chứ không làm.

Client trong realm `bss`:

| Client | Loại | Luồng | Dùng cho |
|---|---|---|---|
| `web-portal` | public, PKCE S256 | Authorization Code | Khách hàng |
| `admin-console` | public, PKCE S256 | Authorization Code | Nhân viên (role `admin`) |
| `api-gateway` (đã có) | public | password grant (**chỉ** script test/E2E) | `e2e-*.sh`, `curl` thủ công |
| `bss-smoke` (mới, cho AWS) | confidential, client credentials | — | `smoke.sh` trong `cd-*` |

## Quyết định 2 — Keycloak có 1 địa chỉ công khai, cùng origin với website, dưới path `/auth`

**Vấn đề gốc:** `iss` trong token phải là **1 giá trị duy nhất**. Trình duyệt thấy Keycloak qua địa
chỉ công khai. Pod trong cluster lại chỉ chắc chắn tới được Keycloak qua DNS nội bộ. Hiện tại repo
chọn "iss = DNS nội bộ", và chính lựa chọn đó làm hỏng luồng trình duyệt.

**Chọn:**
- `KC_HOSTNAME` = **địa chỉ công khai** của môi trường, kèm `KC_HTTP_RELATIVE_PATH=/auth`. Ví dụ
  `http://bss.localtest.me/auth` (kind), `http://<alb-dns>/auth` (AWS khi chưa có domain). Như vậy
  `iss` luôn là địa chỉ công khai. Bật thêm `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` để lời gọi từ
  trong cluster (lấy token trong script, JWKS) dùng được địa chỉ nội bộ.
- Mọi service kiểm JWT cấu hình **2 giá trị tách biệt**:
  - `issuer-uri` = địa chỉ công khai, **chỉ để so khớp** claim `iss`;
  - `jwk-set-uri` = địa chỉ nội bộ `http://keycloak.bss.svc.cluster.local:8080/auth/realms/bss/protocol/openid-connect/certs`,
    để tải khóa công khai.

  Khi có `jwk-set-uri`, Spring Boot tải khóa trực tiếp từ đó và không gọi discovery qua
  `issuer-uri`. Pod vì vậy không bao giờ phải tự resolve địa chỉ công khai.
- **Cùng origin với 2 website (path `/auth`), không dùng subdomain riêng như Giai đoạn 7.** Lý do:
  AWS chưa có domain (quyết định lúc nhận dự án: làm domain sau), nên không tạo được subdomain trên
  DNS của ALB. Path `/auth` thì chạy được y hệt ở kind lẫn AWS. Cùng origin còn loại bỏ luôn CORS
  cho các lời gọi token. Lần thử path `/auth` ở Giai đoạn 7 thất bại vì chỉ sửa 1 trong 2 biến
  (`KC_HOSTNAME`/`KC_HTTP_RELATIVE_PATH`). Lần này đặt cả hai cùng lúc, và phía service không còn
  phụ thuộc discovery.

⚠️ Đánh đổi: trên AWS chưa có domain, địa chỉ ALB chỉ biết **sau khi** Ingress được tạo và đổi sau
mỗi lần `apply` (cluster ephemeral, ADR-006). `KC_HOSTNAME` và `issuer-uri` phải được **điền sau**,
giống cách `scripts/wire-waf.sh` gắn WAF. Khi có domain thật, giá trị này trở thành cố định.

## Quyết định 3 — Khách tự đăng ký; `Customer` gắn với `sub` của Keycloak; admin duyệt mới được mua

Luồng khách hàng:
1. Khách bấm "Đăng ký" trên web-portal và được chuyển sang trang đăng ký của Keycloak (realm bật
   `registrationAllowed`). Role mặc định của realm là `customer`.
2. Quay về web-portal, `GET /customer/me` trả 404 → hiện form **hoàn tất hồ sơ** (họ tên, SĐT).
   Email lấy từ token, không cho sửa. `POST /customer/me` tạo `Customer` với
   `keycloak_user_id = sub`, trạng thái **`Initialized`**.
3. **Admin duyệt** trên admin-console bằng cách đổi trạng thái sang `Active`. Chỉ khách `Active` mới
   đặt hàng được. `Suspended` (khóa) chặn đặt hàng nhưng vẫn cho xem hóa đơn cũ.

| # | Phương án cho bước 3 | Ưu | Nhược |
|---|---|---|---|
| A | Đăng ký xong là `Active` ngay | Ít ma sát | Không có vai trò thật cho admin; không giống nghiệp vụ nhà mạng (phải định danh/KYC trước khi cấp dịch vụ) |
| B | **Admin duyệt `Initialized → Active`** | Đúng vòng đời TMF629 và nghiệp vụ thật; là bằng chứng rõ nhất cho việc 2 website đồng bộ với nhau | Khách phải chờ duyệt; test E2E dài hơn 1 bước |

**Chọn B.** Cột `keycloak_user_id` unique và **nullable**: khách do admin tạo tay (khách tại quầy)
không có tài khoản web.

## Quyết định 4 — Mỗi service tự kiểm JWT, không tin header do gateway chèn

| # | Phương án | Ưu | Nhược |
|---|---|---|---|
| A | Gateway kiểm token rồi chèn `X-User-Id`/`X-User-Roles`, service tin header | Service đơn giản | Bất kỳ Pod nào gọi thẳng service cũng giả mạo được header. NetworkPolicy **chưa được enforce trên EKS** (xem nợ Giai đoạn 7), nên hàng rào mạng chưa có thật |
| B | **Gateway chuyển nguyên header `Authorization`; mỗi service là OAuth2 Resource Server tự kiểm chữ ký + `iss` + hạn** | Zero-trust; không phụ thuộc hàng rào mạng; test được bằng `spring-security-test` | Thêm dependency + cấu hình ở 4 service |

**Chọn B.** Gateway vẫn giữ lớp chặn thô, chủ yếu để trả 401 sớm. Quy tắc sở hữu chi tiết nằm ở
từng service, ngay cạnh dữ liệu.

Khi service gọi service thay mặt người dùng, **chuyển tiếp token của chính người dùng đó**. Ví dụ
order-management gọi `GET /customer/me` của customer-service bằng token của khách. Không dùng một
"tài khoản dịch vụ" có quyền rộng.

## Quyết định 5 — Quyền sở hữu: đóng dấu `owner_sub` lên đơn hàng và hóa đơn

Để billing trả lời được câu "hóa đơn này có phải của người đang gọi không" mà **không** phải gọi sang
customer-service ở mỗi request:
- order-management lưu thêm `owner_sub` (= `sub` trong token) khi tạo đơn. `customerId` lấy từ
  `GET /customer/me` chứ **không lấy từ body request** (body cũ mang `customerId`/`unitPrice` là
  chỗ để giả mạo).
- Event `OrderCompleted` có thêm trường `customerSub`. Đây là thay đổi **chỉ thêm trường**, tương
  thích ngược với schema trong `packages/api-contracts`. Billing đóng dấu trường này lên hóa đơn.
- Quy tắc đọc:

| Role | Đơn hàng / hóa đơn / billing account | Hồ sơ khách |
|---|---|---|
| `customer` | chỉ bản ghi có `owner_sub = sub` của mình. Đọc bản ghi của người khác → **404** (không trả 403, để không lộ việc id đó tồn tại) | chỉ `/customer/me` |
| `admin` | tất cả, lọc được theo `customerId` | tất cả + đổi trạng thái |

Dữ liệu cũ có `owner_sub = NULL` thì chỉ admin thấy. Đây là hành vi đúng: dữ liệu đó thuộc "khách
ma" `DEMO_CUSTOMER_ID`.

Gói cước (product-catalog): đọc công khai (khách chưa đăng nhập vẫn xem được gói); ghi chỉ admin.
Khách chỉ thấy gói `Active`, admin thấy cả gói đã ngừng bán (`Retired`).

## Quyết định 6 — Trên AWS dùng Keycloak (không dùng Cognito)

| # | Phương án | Ưu | Nhược |
|---|---|---|---|
| A | **Keycloak trên EKS** (chế độ production: image `kc.sh build`, DB riêng trên RDS có sẵn, secret qua CSI như B-20) | **1 mô hình duy nhất** cho kind, docker-compose và AWS: cùng realm JSON, cùng claim `realm_access.roles`, cùng code, cùng test E2E | Phải tự vận hành Keycloak (JVM ~768Mi RAM). 2 node t3.medium của dev vốn đã chật (Giai đoạn 8 thấy `FailedScheduling` khi tải cao), có thể phải tăng node |
| B | AWS Cognito | Managed, không phải vận hành | Claim khác (`cognito:groups`) nên cần bộ chuyển đổi thứ 2; **không chạy được ở local** (Cognito trên LocalStack là bản Pro), vi phạm nguyên tắc "local trước, cloud sau"; code và test tách làm 2 nhánh |

**Chọn A.** Chi tiết triển khai (có tăng node dev hay không, số liệu RAM thật) làm ở Giai đoạn 9
việc 7, và **hỏi trước khi `apply`**. Công tắc `bss.auth.enabled` bị **xóa** khi cả 4 môi trường
(local, dev, staging, prod) đã có Keycloak. Từ đó auth luôn bật, không còn môi trường nào "mở".

## Hệ quả

- ✅ Một người thật dùng được 2 website từ đầu đến cuối. Dữ liệu 2 bên đồng bộ vì cùng một danh tính
  (`sub`) và cùng một nguồn dữ liệu, không phải nhờ ID cố định.
- ✅ B-18 đóng thật ở mọi môi trường (sau việc 7). Không còn endpoint ghi nào mở.
- ✅ Dọn luôn phần còn lại của B-13: `unitPrice` và `customerId` không còn nhận từ client.
- ⚠️ Mọi test IT hiện có gọi API không kèm token sẽ đỏ khi bật resource server. Phải cập nhật bằng
  `spring-security-test` (`jwt()`), không mock framework (đúng CLAUDE.md §9).
- ⚠️ Script `e2e-local.sh` và `e2e-kind.sh` phải tự lấy token (client `api-gateway`, password
  grant, chỉ cho test).
- ⚠️ docker-compose thêm 1 container Keycloak (~768Mi RAM) cho môi trường local.
- ⚠️ Trên AWS, Keycloak làm tăng thời gian dựng cluster ephemeral (chờ Keycloak `Ready`) và tăng
  RAM cần có. Số liệu thật ghi lại ở việc 7.

## Tự kiểm tra

1. Vì sao `iss` = DNS nội bộ lại chạy được với `curl` + password grant, nhưng hỏng ngay khi dùng
   trình duyệt + Authorization Code? Vẽ đường đi của redirect ở bước "chuyển sang trang đăng nhập".
2. Khách A biết `id` hóa đơn của khách B, gọi `GET /customerBill/{id}` bằng token của A. Service nên
   trả 403 hay 404? Vì sao ADR chọn 404?
3. Nếu chọn phương án A của quyết định 4 (tin header `X-User-Id`), kẻ tấn công cần đứng ở đâu để
   giả mạo được danh tính? NetworkPolicy (Giai đoạn 7) đóng được lỗ đó ở môi trường nào, và chưa
   đóng ở môi trường nào?

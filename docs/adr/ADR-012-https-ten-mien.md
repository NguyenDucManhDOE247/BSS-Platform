# ADR-012 — HTTPS + tên miền trên AWS: Route 53 ở shared, cert ACM wildcard, ExternalDNS, Keycloak công khai có giới hạn

- **Trạng thái:** Chấp nhận (Accepted) — đóng B-23; thay [ADR-008 quyết định 8](ADR-008-danh-tinh-va-quyen-so-huu.md).
- **Ngày:** 2026-10-01
- **Liên quan:** [ADR-003](ADR-003-terraform-shared-state.md) (state shared), [ADR-006](ADR-006-staging-prod-ephemeral.md)
  (môi trường ephemeral), [ADR-008](ADR-008-danh-tinh-va-quyen-so-huu.md) (danh tính), [ADR-011](ADR-011-keycloak-production-grade.md)
  (Keycloak production-grade).

## Bối cảnh

Tới `v2.1.0`, AWS chạy **HTTP** trên tên DNS tự sinh của ALB. ADR-008 quyết định 8 chấp nhận tạm: auth bật
ở tầng API, nhưng **không đăng nhập được bằng trình duyệt** (PKCE cần `crypto.subtle` — chỉ có trong secure
context), Keycloak không mở ra ALB, `iss` của token là DNS nội bộ. Thiếu duy nhất 1 thứ: tên miền.

Chủ repo đăng ký **`bssplatform.dpdns.org`** (DigitalPlat — miễn phí, thời hạn 1 năm, cho đổi name server).
Đã kiểm trước khi thiết kế: không có bản ghi CAA ở `bssplatform.dpdns.org` / `dpdns.org` / `org` → ACM được
phép cấp cert (CAA chặn là lý do phổ biến khiến ACM từ chối với miền con của nhà cung cấp miễn phí).

## Quyết định

### 1. Hosted zone + cert nằm ở state `shared`, không ở từng môi trường

| | Zone/cert theo môi trường | **Zone/cert ở shared (chọn)** |
|---|---|---|
| NS ở nhà đăng ký | Mỗi zone mới = 4 NS mới → mỗi buổi dựng lại phải sửa tay ở DigitalPlat + chờ lan truyền | Nhập **1 lần** |
| Cert ACM | Xác thực DNS lại mỗi buổi (vài phút, có khi lâu hơn) | Cấp 1 lần, ACM tự gia hạn |
| Chi phí | $0.50/tháng/zone, chỉ khi môi trường sống | **$0.50/tháng** cố định + $0.40/triệu truy vấn |
| Cô lập | Hoàn toàn | Chung zone → phải giới hạn IAM theo tên (mục 3) |

Áp dụng 2 bước (`dns_delegated`): cert chỉ được cấp **sau** khi NS công khai trỏ về Route 53 — tách để apply
đầu không treo chờ một việc con người chưa làm.

### 2. Một cert apex + wildcard, ALB tự tìm cert

`bssplatform.dpdns.org` + `*.bssplatform.dpdns.org` phủ: prod ở **apex**, `dev.` và `staging.`. Overlay **không**
ghi ARN cert — AWS Load Balancer Controller tự tìm cert ACM khớp host của Ingress. Cấp lại cert (ARN đổi)
không phải sửa manifest. Đánh đổi: nếu account có 2 cert cùng phủ 1 host, controller chọn theo quy tắc của
nó — chấp nhận vì account chỉ có 1. TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.2+, có 1.3).

### 3. ExternalDNS — mỗi cluster chỉ được ghi tên của mình

ExternalDNS (chart 1.23.0) tạo alias A trỏ vào ALB từ host của Ingress, `policy: sync` (xóa khi Ingress mất),
TXT "sở hữu" `external-dns/owner=<cluster>`. Role IRSA chỉ có `ChangeResourceRecordSets` với điều kiện
`route53:ChangeResourceRecordSetsNormalizedRecordNames` ∈ {`<host>`, `*-<host>`} — cluster staging bị chiếm
cũng không ghi đè được apex của prod.

Cái giá của zone sống lâu hơn cluster: destroy giết ExternalDNS trước khi nó xóa bản ghi → bản ghi treo trỏ
vào ALB đã chết. `teardown.sh` chờ (≤ 3 phút, theo TXT sở hữu) sau khi xóa Ingress; `orphan_finder.py` báo
bản ghi của cluster không còn tồn tại.

### 4. Keycloak ra internet — nhưng chỉ phần trình duyệt cần

- Ingress: chỉ `/auth/realms` (đăng nhập, đăng ký, token, JWKS) và `/auth/resources` (CSS/JS trang đăng nhập).
  **`/auth/admin` không có route** → rơi vào `/` (web-portal). Quản trị Keycloak vẫn qua `kubectl port-forward`.
- `KC_HOSTNAME=https://<host>/auth` theo từng overlay → `iss` cố định, trùng `…_JWT_ISSUER_URI` của 5 service
  Spring (JWKS vẫn tải qua DNS nội bộ). `KC_PROXY_HEADERS=xforwarded`: ALB kết thúc TLS, Keycloak cần biết
  request gốc là HTTPS (realm `sslRequired: external`).
- NetworkPolicy: thêm `ipBlock` = dải subnet **public** của VPC (ALB đặt ENI ở đó; Pod + node ở subnet private)
  → Pod lạ trong cluster vẫn bị chặn (ô "kẻ lạ → keycloak" của `netpol-matrix.sh` giữ BLOCKED).
- Health check ALB cho target Keycloak: `/auth/realms/bss` qua cổng 8080 (annotation trên Service) — không mở
  cổng quản trị 9000.
- Realm: thêm 3 host HTTPS vào `redirectUris` / `webOrigins` / post-logout của `web-portal` + `admin-console`;
  bỏ `rootUrl: http://bss.localhost` (đường dẫn tương đối tự theo host đang dùng).

### 5. Mở Keycloak ra internet ⇒ phải xem lại `.trivyignore`

Lý do giảm rủi ro cũ của 6 CVE bị bỏ qua (ADR-011 mục 5) là "Keycloak không mở ra ALB" — hết hiệu lực. Quét
thật: **26.7.4** còn thêm 2 CVE HIGH mới (jackson-databind CVE-2026-91776/91777); **26.7.5** (bản vá ra 30/9)
chỉ còn driver mssql-jdbc không bao giờ được nạp; 26.8.0 sạch nhưng là bản `.0` và nâng minor phải scale về 0.
→ Nâng **26.7.5**, `.trivyignore` còn 1 dòng.

### 6. Smoke đi bằng HTTPS thật nhưng không phụ thuộc DNS công khai

`smoke.sh` đọc host từ Ingress, gọi `https://<host>` với cert thật (không `-k`) qua `curl --connect-to
<host>:443:<ALB>:443`. Lý do: bản ghi ExternalDNS có sau ALB ~1 phút; resolver nào hỏi sớm sẽ nhớ NXDOMAIN tới
15 phút (TTL âm của SOA Route 53 = 900 s) → smoke đỏ oan → CD rollback oan. Thêm 3 kiểm: HTTP→HTTPS 301; OIDC
discovery có `issuer == https://<host>/auth/realms/bss`; `/auth/admin/realms` **không** trả 401 của Keycloak.

## Hệ quả

- **Đăng nhập web chạy trên AWS** (B-18 phần web) — cùng image frontend, không build lại (frontend đã tính
  authority = `window.location.origin + /auth/realms/bss`).
- Mật khẩu người dùng + token đi qua HTTPS; port 80 chỉ còn 301.
- Bước tay còn lại, **1 lần**: nhập 4 NS vào DigitalPlat. Miền miễn phí hết hạn 2027-10-01 — gia hạn miễn phí
  trong 120 ngày cuối (ghi trong `docs/runbooks/https-domain.md`).
- Rủi ro chấp nhận: nhà cung cấp miền miễn phí có thể thu hồi/ngừng dịch vụ — mất miền thì chỉ cần đổi
  `domain_name` + host trong 3 overlay + realm, kiến trúc không đổi.

## Bằng chứng (chạy thật — không suy đoán)

| Bước (2026-10-01) | Kết quả |
|---|---|
| `terraform plan` shared lần đầu | 2 lỗi thật `Invalid for_each argument` (khóa theo tên bản ghi xác thực, rồi theo `dvo.domain_name` — cert dùng `count` nên cả tập unknown lúc plan) → khóa theo 2 tên khai báo |
| Apply 1 (shared) | 4 resource: zone `Z0030846ZUQU1KLU0V2B`, cert, 2 bản ghi xác thực — **cùng 1 CNAME** cho apex + wildcard (`allow_overwrite` đúng là cần) |
| NS ở DigitalPlat | `ns1.dpdns.org` ủy quyền ngay; Cloudflare + Google thấy NS mới sau **~200 s** |
| Apply 2 (`dns_delegated = true`) | Cert **ISSUED sau 44 s**, hạn 2027-04-17 |
| Dev EKS | _(điền khi chạy)_ |

### Lưu ý gia hạn cert

`RenewalEligibility = INELIGIBLE` lúc mới cấp: ACM chỉ tự gia hạn cert **đang gắn vào tài nguyên AWS** (ALB).
ALB của dự án là ephemeral (ADR-006) → nếu tới khoảng 60 ngày trước 2027-04-17 không môi trường nào đang chạy,
cert có thể hết hạn. Cách xử lý (đã ghi ở runbook): `terraform apply -replace=aws_acm_certificate.main[0]`
trong shared — `create_before_destroy` cấp cert mới qua cùng bản ghi CNAME, không phải đụng NS.
# Runbook: danh tính & phân quyền (Keycloak + OIDC/PKCE + quyền sở hữu)

Thiết kế và lý do: [ADR-008](../adr/ADR-008-danh-tinh-va-quyen-so-huu.md). Runbook này trả lời
"đang chạy thế nào, kiểm ra sao, hỏng thì sửa ở đâu". Viết lại ở Giai đoạn 9 việc 8 (bản GĐ7 mô tả
trạng thái cũ: chỉ kind có auth, frontend chưa đăng nhập được, chưa có quyền sở hữu).

## 1. Bức tranh chung

```
Trình duyệt ──(Authorization Code + PKCE)──► Keycloak realm "bss"  ──► access token (JWT, RS256)
     │                                                                   sub, email, realm_access.roles
     └── Bearer token ──► api-gateway ──► customer / catalog / order / billing
                          (chặn thô:         (MỖI service tự kiểm chữ ký + iss + hạn,
                           401 / 403)          rồi áp luật sở hữu theo `sub`)
```

- **Realm `bss`** dùng chung mọi môi trường: `infrastructure/kubernetes/components/keycloak-realm/bss-realm.json`
  (2 role `admin`/`customer`, role mặc định của người tự đăng ký = `customer`; client `web-portal`,
  `admin-console` là public client PKCE S256; `api-gateway` bật password grant — CHỈ cho script/test).
  **Không có user nào** trong file realm. 2 user thử (`admin1`/`admin1pass`, `customer1`/`customer1pass`)
  chỉ tồn tại ở local: `overlays/local/keycloak/bss-users-0.json` (kind + docker-compose).
- **Khách tự đăng ký** trên web-portal (trang của Keycloak) → tự tạo hồ sơ `POST /customer/me` → trạng
  thái `Initialized` → **admin duyệt** trên admin-console (`→ Active`) mới được đặt hàng. `Suspended` =
  khóa (không đặt hàng được, vẫn xem hóa đơn cũ).
- **Zero-trust:** gateway chỉ chặn thô; mỗi service tự kiểm JWT (không tin header do gateway chèn) —
  Pod nào gọi thẳng service bỏ qua gateway cũng không giả danh được ai.

## 2. Luật phân quyền

**Gateway** (`apps/backend/api-gateway/.../SecurityConfig.java`, khi `bss.auth.enabled=true`):

| Route | Yêu cầu |
|---|---|
| `/actuator/**` | Công khai (probe, Prometheus) |
| `GET /api/tmf-api/productCatalog/**` | Công khai — khách chưa đăng nhập vẫn xem gói |
| `/api/tmf-api/customerManagement/v4/customer/me` | Đã đăng nhập |
| `/api/tmf-api/customerManagement/**` (còn lại) | Role `admin` |
| Mọi thứ khác | Đã đăng nhập — luật chi tiết ở từng service |

**Service** (quyền sở hữu — ADR-008 quyết định 4, 5):

| Service | Khách (`customer`) | Admin |
|---|---|---|
| customer | Chỉ hồ sơ của mình (`/me`); email lấy từ token, không từ body | CRUD, lọc/tìm, duyệt/khóa |
| catalog | Chỉ thấy gói `Active` | Tạo, sửa giá, ngừng bán (`Retired`) |
| order | `customerId` lấy từ hồ sơ của token (body bị bỏ qua); phải `Active` (422 nếu chưa); chỉ đọc đơn của mình | Mọi đơn, lọc theo khách |
| billing | Chỉ hóa đơn/billing account của mình (chủ sở hữu từ `customerSub` trong event) | Mọi hóa đơn + `GET /customerBill/summary` (doanh thu) |

Đọc dữ liệu của người khác trả **404, không phải 403** — 403 tiết lộ rằng id đó tồn tại.

## 3. Theo môi trường

| | kind (`overlays/local`) | docker-compose + `mvn` | AWS dev/staging/prod |
|---|---|---|---|
| Keycloak | 26.7.4 gốc, `start-dev`, H2 trong emptyDir | 26.7.4 gốc, `localhost:8180/auth` | Image riêng `bss/keycloak` (`apps/identity/keycloak`, ADR-011): `start --optimized`, rootfs chỉ đọc, Postgres riêng trên RDS, secret qua CSI; **prod 2 replica** (dev/staging 1) |
| Auth backend | Bật | **Tắt** (`bss.auth.enabled` mặc định) | Bật |
| `KC_HOSTNAME` / `iss` | `http://bss.localhost/auth` | `http://localhost:8180/auth` | `http://keycloak.bss.svc.cluster.local:8080/auth` (DNS nội bộ) |
| Keycloak qua Ingress | Có, path `/auth` | — | **Không** (chưa có HTTPS — ADR-008 quyết định 8) |
| Đăng nhập bằng trình duyệt | ✅ | ✅ | ❌ chờ HTTPS + domain |

Vì sao `bss.localhost` mà không phải `bss.localtest.me`: PKCE cần `crypto.subtle`, trình duyệt chỉ cấp
trong **secure context** (HTTPS hoặc `*.localhost`) — ADR-008 quyết định 7. Cùng lý do đó AWS chưa có
đăng nhập web.

Khi có HTTPS trên AWS, đổi 3 chỗ (không sửa code): `KC_HOSTNAME` → `https://<domain>/auth`, `issuer-uri`
của 5 service, thêm path `/auth` vào Ingress AWS (+ redirect URI của 2 client SPA).

## 4. Cài đặt

```bash
# kind
./scripts/auth-install.sh kind                              # Secret keycloak-admin (idempotent)
kubectl apply -k infrastructure/kubernetes/overlays/local
kubectl -n bss rollout status deploy/keycloak

# AWS: Keycloak đi cùng overlay (không bước riêng) — nhưng db-bootstrap phải tạo database "keycloak":
kubectl apply -k infrastructure/kubernetes/overlays/<env>/db-bootstrap   # "all 5 databases ready"
```

Mật khẩu admin master realm: kind — Secret `keycloak-admin` (script sinh); AWS — Secrets Manager
`bss-<env>/keycloak/admin` (Terraform sinh ngẫu nhiên) → CSI → K8s Secret `keycloak-admin`.

## 5. Lấy token + kiểm tra

**kind** (password grant qua client `api-gateway` — chỉ cho test):

```bash
TOK=$(curl -s http://bss.localhost/auth/realms/bss/protocol/openid-connect/token \
  -d grant_type=password -d client_id=api-gateway -d username=admin1 -d password=admin1pass | jq -r .access_token)
curl -s -o /dev/null -w '%{http_code}\n' http://bss.localhost/api/tmf-api/productCatalog/v4/productOffering   # 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://bss.localhost/api/tmf-api/orderManagement/v4/productOrder # 401
curl -s -H "Authorization: Bearer $TOK" http://bss.localhost/api/tmf-api/customerManagement/v4/customer | jq length
```

**AWS** — Keycloak không mở ra ALB, nên đi qua `kubectl port-forward` (API server, có TLS; mật khẩu admin
không đi qua HTTP ngoài internet). `scripts/smoke.sh <env>` làm đúng việc này: tạo/đặt lại mật khẩu user
`smoke-bot` (role customer) qua Admin REST API rồi kiểm: công khai 200, không token 401, `/me` 200|404,
API quản trị 403.

```bash
kubectl -n bss port-forward svc/keycloak 18080:8080 &
# token: http://127.0.0.1:18080/auth/realms/bss/protocol/openid-connect/token (iss vẫn là DNS nội bộ)
```

**Bộ kiểm tự động** (chạy theo thứ tự, mỗi cái bắt 1 loại lỗi khác):

| Lệnh | Kiểm gì |
|---|---|
| `mvn verify` từng service (`*AuthIT`) | Luật sở hữu với JWT giả (`spring-security-test`), Postgres thật |
| `npm test` 2 app | AdminGate, luồng duyệt/khóa, interceptor |
| `./scripts/e2e-kind.sh` | Luồng API: user Keycloak mới → hồ sơ → 422 → duyệt → mua → hóa đơn → khách khác 404 |
| `./scripts/e2e-browser.sh` | Playwright trình duyệt thật: đăng ký → duyệt trên admin-console → mua → đơn/hóa đơn |
| `./scripts/smoke.sh <env>` | Smoke có token trên AWS (chạy trong CD, hỏng thì rollback) |

## 6. Vận hành thường gặp

| Việc | Cách |
|---|---|
| Duyệt / khóa khách | admin-console → Khách hàng → lọc "Initialized" → Duyệt / Khóa |
| Thêm nhân viên admin (AWS) | port-forward Keycloak → Admin console `http://127.0.0.1:18080/auth/admin` (tài khoản master) → Users → gán realm role `admin` |
| Khách báo "đã đăng nhập mà không mua được" | Xem trạng thái hồ sơ: `Initialized` = chưa duyệt (422 kèm thông báo), `Suspended` = bị khóa |
| Mọi request 401 dù token mới | `iss` không khớp `issuer-uri` (đổi hostname Keycloak mà quên 5 service) — so `jq -R 'split(".")[1] \| @base64d \| fromjson \| .iss'` với cấu hình |

## 7. Bug thật đã gặp (đọc trước khi tự làm lại)

| Triệu chứng | Nguyên nhân | Sửa |
|---|---|---|
| `Account is not fully set up` khi xin token | Realm mặc định bật `VERIFY_PROFILE` | `requiredActions` cấp realm `VERIFY_EMAIL`/`VERIFY_PROFILE` = `enabled: false` |
| Keycloak CrashLoop `ReadOnlyFileSystemException` | `start`/`start-dev` không `--optimized` "augment" Quarkus lúc khởi động, ghi vào `/opt/keycloak/lib` | AWS: image `kc.sh build` + `start --optimized` (ADR-011) → rootfs chỉ đọc. kind vẫn `start-dev` (luôn augment) → giữ `false` ở `overlays/local` |
| Pod Keycloak thứ hai `Error` 1 lần ngay khi dựng môi trường mới (`duplicate key … pg_type_typname_nsp_index`) | 2 Pod cùng tạo bảng Liquibase trên DB **trống** | Không cần làm gì: kubelet khởi động lại, Pod vào cluster. Chỉ xảy ra lần đầu (ADR-011 §3) |
| Trivy báo CVE CRITICAL ở Keycloak 26.5.x (CVE-2026-18963 chiếm tài khoản) | Keycloak là image bên thứ ba, trước ADR-011 không qua Trivy | Nâng 26.7.4 + `ci-keycloak.yml` quét mỗi PR |
| Probe 404 dù Keycloak khỏe | Keycloak 26 phục vụ `/health/*` ở cổng quản trị 9000 | Probe port 9000 + `KC_HTTP_MANAGEMENT_RELATIVE_PATH=/` |
| Trình duyệt bị chuyển tới `keycloak.bss.svc.cluster.local` | `KC_HOSTNAME` = DNS nội bộ (GĐ7) | kind: hostname công khai + `jwk-set-uri` nội bộ; AWS: cố ý nội bộ, không có đăng nhập web |
| Bấm "Đăng nhập" không có gì xảy ra (GĐ9) | `http://bss.localtest.me` không phải secure context → không có `crypto.subtle`, lỗi nằm im trong `auth.error` | Host kind → `bss.localhost` |
| `hasRole("admin")` luôn từ chối | Role nằm trong `realm_access.roles` (lồng), không phải `scope` | Converter tùy biến đọc `realm_access.roles` + tiền tố `ROLE_` |
| Hàng loạt 401 trên kind sau khi `apply` | Keycloak local rollout → Pod mới (H2 mới) có **khóa ký mới** → token của Pod cũ vô hiệu | Đặc thù local (H2 trong emptyDir) — lấy token mới; AWS dùng Postgres nên không bị |
| Playwright đỏ ngẫu nhiên ở bước duyệt | Test đổi bộ lọc trước khi PATCH ghi xong | Chờ response 2xx trước khi thao tác tiếp (`helpers.ts`) |

## 8. Keycloak nhiều replica (ADR-011)

- Các Pod tìm nhau qua **database** (`jdbc-ping`, bảng JGROUPSPING) — không có headless Service. Cổng
  JGroups 7800/57800 (mTLS tự động) chỉ mở giữa Pod Keycloak (`allow-to-keycloak`).
- Session người dùng nằm trong DB (persistent sessions) → 1 Pod chết, người dùng không phải đăng nhập lại.
- Xem cluster: `kubectl -n bss logs deploy/keycloak | grep ISPN000094` → phải thấy `(2)` ở prod.

### Kiểm Keycloak HA trên EKS (chạy khi có prod/dev thật — chưa chạy lần nào)

```bash
kubectl -n bss get pods -l app=keycloak -o wide            # prod: 2 Pod, khác node (và nếu được, khác AZ)
kubectl -n bss logs -l app=keycloak --tail=-1 | grep ISPN000094 | tail -2   # "(2)"
kubectl -n bss get pdb keycloak                             # ALLOWED DISRUPTIONS 1
./scripts/netpol-matrix.sh                                  # có dòng "kẻ lạ → Pod keycloak:7800 … BLOCKED"
# Chịu lỗi: xóa 1 Pod trong khi smoke chạy lại — không được đỏ
kubectl -n bss delete pod "$(kubectl -n bss get pod -l app=keycloak -o name | head -1 | cut -d/ -f2)" --wait=false
./scripts/smoke.sh prod
```

### Nâng version Keycloak

1. Sửa `ARG KEYCLOAK_VERSION` ở `apps/identity/keycloak/Dockerfile` **và** image ở
   `overlays/local/keycloak/deployment.yaml` + `deploy/docker-compose.yml` (cùng 1 bản ở mọi nơi).
2. PR → `ci-keycloak.yml` (build + Trivy + chạy thử 2 replica) → xem lại `.trivyignore` (xóa dòng đã vá).
3. Kiểm local: kind (`e2e-kind.sh`, `e2e-browser.sh`).
4. **Patch** (26.7.x → 26.7.y): merge, CD rolling update bình thường. **Minor/major** (26.7 → 26.8):
   Keycloak không hỗ trợ 2 bản khác minor chạy chung 1 cluster/DB → trước khi deploy
   `kubectl -n bss scale deploy/keycloak --replicas=0`, để CD áp bản mới (Pod đầu migrate schema), rồi
   mới trả số replica. Với môi trường ephemeral (ADR-006) dựng mới thì không cần.

## 9. Còn lại

- **HTTPS + đăng nhập web trên AWS** (domain + ACM hoặc CloudFront) — mục "Để sau" trong lộ trình.
- **Xóa công tắc `bss.auth.enabled`**: cần `e2e-local.sh` (mvn) lấy token từ Keycloak của docker-compose.
- **Chạy "Kiểm Keycloak HA trên EKS"** ở mục 8 lần đầu (cần `terraform apply` shared để có repo `bss/keycloak`).

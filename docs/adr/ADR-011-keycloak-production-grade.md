# ADR-011 — Keycloak production-grade: image optimized, rootfs chỉ đọc, nhiều replica, CD quản lý

- **Trạng thái:** Chấp nhận (Accepted) — chủ repo yêu cầu làm 2026-09-30 (mục "Để sau" của Giai đoạn 9).
- **Ngày:** 2026-09-30
- **Liên quan:** [ADR-008](ADR-008-danh-tinh-va-quyen-so-huu.md) (danh tính — Keycloak trên EKS),
  [ADR-005](ADR-005-nguon-su-that-phien-ban-cd.md) (nguồn sự thật phiên bản CD),
  [ADR-006](ADR-006-staging-prod-ephemeral.md) (staging/prod ephemeral).

## Bối cảnh

Giai đoạn 9 việc 7 đưa Keycloak lên EKS ở dạng "chạy được", còn 2 nợ ghi rõ trong manifest:

1. **Ngoại lệ `readOnlyRootFilesystem: false`** — duy nhất trong repo (CLAUDE.md §7). Nguyên nhân: image gốc
   `quay.io/keycloak/keycloak` chạy `kc.sh start` (không `--optimized`) thực hiện bước "augmentation" của
   Quarkus **mỗi lần khởi động**, ghi vào `/opt/keycloak/lib/quarkus`. Hệ quả phụ: khởi động chậm
   (startupProbe phải chờ tới 5 phút).
2. **1 replica ở mọi môi trường, kể cả prod** (`KC_CACHE=local`, `strategy: Recreate`): Pod chết là không
   ai đăng nhập được cho tới khi Pod mới lên.

Khi rà lại để làm, lộ thêm 1 vấn đề nghiêm trọng hơn: **Trivy trên Keycloak 26.5.7** (bản vá cuối của
dòng 26.5 mà repo dùng ở kind, docker-compose lẫn AWS) báo nhiều CVE của **chính Keycloak**, trong đó
**CVE-2026-18963 (CRITICAL) — chiếm tài khoản không cần xác thực qua luồng reset-credentials**, chỉ vá ở
26.4.15 / 26.6.6 / 26.7.2+. Trước đây Keycloak không qua Trivy vì là image bên thứ ba, không do CI build.

## Quyết định

### 1. Image riêng `apps/identity/keycloak` — `kc.sh build` lúc build, `start --optimized` lúc chạy

```dockerfile
FROM quay.io/keycloak/keycloak:26.7.4 AS builder
ENV KC_DB=postgres KC_HEALTH_ENABLED=true KC_METRICS_ENABLED=true \
    KC_HTTP_RELATIVE_PATH=/auth KC_HTTP_MANAGEMENT_RELATIVE_PATH=/
RUN /opt/keycloak/bin/kc.sh build
FROM quay.io/keycloak/keycloak:26.7.4
COPY --from=builder /opt/keycloak/ /opt/keycloak/
CMD ["start", "--optimized"]
```

- Build option (db, health, metrics, 2 relative path) đóng băng trong image; mọi thứ khác (DB
  host/user, hostname, cache, log) vẫn là biến môi trường lúc chạy.
- `readOnlyRootFilesystem: true`; Keycloak chỉ ghi vào 2 emptyDir: `/tmp` và `/opt/keycloak/data`.
- **Nâng 26.5 → 26.7.4 ở MỌI nơi** (image này + `overlays/local/keycloak` + `deploy/docker-compose.yml`)
  để realm/test chạy cùng một bản.
- Local (kind, docker-compose) **vẫn** dùng image gốc với `start-dev` + H2: đó là môi trường thử, không
  cần image riêng, và `start-dev` luôn augment lúc khởi động bất kể image.

### 2. Nhiều replica: cache `ispn` + discovery `jdbc-ping` (mặc định Keycloak 26.x)

- Bỏ `KC_CACHE=local` → cache phân tán mặc định. Keycloak 26.x dò các Pod khác qua **chính database**
  (`jdbc-ping`, bảng JGROUPSPING trên RDS) — **không** cần headless Service/DNS_PING như ghi chú nợ cũ.
- Kênh JGroups (cổng 7800, dò lỗi 57800) mã hóa mTLS tự động (`cache-embedded-mtls-enabled` mặc định
  `true`). NetworkPolicy `allow-to-keycloak` thêm 1 rule: chỉ Pod Keycloak gọi nhau ở 2 cổng này.
- **Persistent user sessions** (mặc định từ Keycloak 25): session nằm trong DB → Pod chết/khởi động lại,
  người dùng không phải đăng nhập lại.
- Replica: **prod 2**, dev/staging 1 (tiết kiệm; dev còn Karpenter). Prod thêm 250m CPU — tổng requests
  prod 4.35 vCPU app + ~1.3 hệ thống ≈ 5.65 / 7.72 vCPU allocatable của 4 × t3.large, vẫn vừa quota 8 vCPU.
- `strategy: RollingUpdate` (`maxSurge 1, maxUnavailable 0`) thay cho `Recreate`. Giới hạn của Keycloak:
  rolling update chỉ an toàn giữa các bản **patch**; nâng minor/major phải scale về 0 trước
  (`docs/runbooks/auth.md` → "Nâng version Keycloak").
- `topologySpreadConstraints` theo zone + hostname (`ScheduleAnyway`).
- **PDB `maxUnavailable: 1`** (khác `minAvailable: 1` của 7 service): với 1 replica ở dev/staging,
  `minAvailable: 1` chặn mọi lần drain node (bài học Lab 08); `maxUnavailable: 1` vẫn bảo đảm prod còn 1 Pod.

### 3. Deployment, không phải StatefulSet — chấp nhận 1 lần restart trên DB TRỐNG

**Lỗi thật tái hiện được 2/2 lần** (cả 26.5.7 lẫn 26.7.4): 2 Pod cùng khởi động trên database **trống**
→ Pod thứ hai chết vì tranh tạo bảng Liquibase (`duplicate key value violates unique constraint
"pg_type_typname_nsp_index"`). Khởi động lại thì nó vào cluster bình thường. Chỉ xảy ra ở **lần deploy
đầu của môi trường mới** (với ADR-006 là mỗi lần dựng prod), không xảy ra khi rolling update.

| Phương án | Ưu | Nhược |
|---|---|---|
| **A. Deployment, để kubelet restart 1 lần (chọn)** | Mọi công cụ CD (`rollout status deployment/…`, `verify-cluster` đọc `get deployments`, preflight `deployments.apps`) giữ nguyên | Pod thứ hai có 1 restart ở lần dựng đầu — phải ghi rõ để không bị hiểu nhầm là sự cố |
| B. StatefulSet `OrderedReady` (cách Keycloak Operator làm) | Pod 2 chỉ lên khi Pod 1 Ready → không bao giờ tranh | Đổi release-manifest (`verify-cluster`), composite action (`rollout status`), preflight — chỉ để tránh 1 restart có hại đúng 0 |
| C. Keycloak Operator | Chuẩn của dự án Keycloak | Thêm CRD + controller phải vận hành, lệch hẳn cách 7 service kia được deploy (ADR-005) |

Điều kiện xem lại: nếu restart đó làm đỏ smoke/rollout thật trên EKS, hoặc khi prod cần > 2 replica.

### 4. CD quản lý Keycloak như image thứ 8 (ADR-005)

- `scripts/release-manifest.sh`: `SERVICES` thêm `keycloak` → `dir keycloak` = `apps/identity/keycloak`;
  tag = commit cuối chạm thư mục đó; build ở `cd-dev` khi ECR chưa có; promote bằng `ecr put-image`; kiểm
  drift; rollback cùng manifest. ECR thêm repo `bss/keycloak` (`modules/ecr`, state `shared`).
- **Manifest cũ trên nhánh `deploy-state`** (dev/staging/prod.json ghi trước ADR này) chỉ có 7 service →
  không dùng làm đích rollback được (thiếu tag keycloak). Lệnh mới `release-manifest.sh previous` nhận
  diện đúng trường hợp đó, in rỗng + thông báo ("lần này không rollback được"); lần deploy PASS kế tiếp
  ghi manifest 8 image. Manifest hỏng kiểu khác vẫn làm run đỏ.
- CI mới `ci-keycloak.yml`: build + Trivy + **chạy thật 2 replica trên Postgres, rootfs chỉ đọc**
  (phải thành cluster 2 node và refresh token cấp ở Pod 1 dùng được ở Pod 2).

### 5. Trivy: vá cái vá được, ghi lý do cái chưa vá được

26.7.4 vá toàn bộ CVE của chính Keycloak. Còn 6 CVE HIGH/CRITICAL ở **thư viện đóng gói sẵn** (netty,
freemarker, bouncycastle ×2, jackson-databind, driver mssql không được nạp) — bản vá có ở thư viện gốc
nhưng chưa có bản Keycloak nào đóng gói. Thay jar thủ công không được hỗ trợ (classpath đã được augment
và lập chỉ mục) → ghi `apps/identity/keycloak/.trivyignore` kèm lý do, xem lại mỗi bản Keycloak mới. Rủi
ro còn lại được giảm vì Keycloak trên AWS không mở ra ALB (ADR-008 quyết định 8).

> **2026-10-01 — [ADR-012](ADR-012-https-ten-mien.md):** Keycloak mở ra internet (HTTPS) → lý do trên hết hiệu lực.
> Nâng 26.7.5, `.trivyignore` chỉ còn driver mssql-jdbc không được nạp.

## Bằng chứng (chạy thật, 2026-09-30 — không suy đoán)

| Kiểm | Kết quả |
|---|---|
| Image optimized, 2 container + Postgres 16, `--read-only` | Khởi động **4–6 s** (trước: startupProbe chờ tới 5 phút); `touch /opt/keycloak/lib/x` → `Read-only file system` |
| Cluster | `ISPN000094 … cluster view (2)` qua jdbc-ping |
| Session chung | refresh token cấp ở Pod 1 → Pod 2 trả **200** |
| Persistent session | tắt CẢ 2 Pod, bật 1 Pod, dùng lại refresh token cũ → **200** |
| DB trống, 2 Pod cùng lúc | Pod 2 chết 1 lần (Liquibase), khởi động lại → vào cluster (tái hiện 2/2) |
| Trivy 26.5.7 → 26.7.4 | CVE của Keycloak: có CRITICAL (CVE-2026-18963) → **0**; còn 6 ở thư viện đóng gói (`.trivyignore`) |
| kind (Keycloak 26.7.4, `start-dev`) | `scripts/e2e-kind.sh` **PASS toàn bộ**; Playwright **3/3**; `netpol-matrix.sh` 10/10 |
| `release-manifest.test.sh` | **68/68** (61 cũ + 7 mới: keycloak, `previous` với manifest cũ/hỏng) |
| Bước "chạy thử 2 replica" của `ci-keycloak.yml` chạy tại máy | PASS |

**Chưa chạy trên EKS** (cần `terraform apply` shared để có repo `bss/keycloak` + dựng dev/prod — hỏi
trước khi tốn tiền, CLAUDE.md §9). Checklist khi chạy: `docs/runbooks/auth.md` → "Kiểm Keycloak HA trên EKS".

## Hệ quả

- ✅ Không còn ngoại lệ `readOnlyRootFilesystem` nào trong repo.
- ✅ Prod chịu được 1 Pod Keycloak chết/bị drain mà không mất đăng nhập.
- ✅ Keycloak qua cùng cổng Trivy như 7 image kia; nâng version = sửa 1 ARG + 2 dòng image local, CD
  build/promote như mọi service.
- ⚠️ Nâng minor/major Keycloak cần quy trình riêng (scale 0) — không tự động bằng rolling update.
- ⚠️ `.trivyignore` có 6 dòng phải được xem lại định kỳ — không phải "đã an toàn".
- ⚠️ Lần deploy đầu sau khi merge: không có last-known-good dùng được (manifest cũ 7 service).

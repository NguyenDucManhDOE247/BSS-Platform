# ADR-004 — Cách service lấy RDS host/port/user trên dev (B-20)

- **Trạng thái:** Chấp nhận (Accepted)
- **Ngày:** 2026-09-23
- **Giai đoạn:** 5 — Deploy dev lên EKS

## Bối cảnh

**B-20**: 4 Deployment tham chiếu `secretKeyRef` tới các Secret (`customer-db-credentials`...)
mà không ai tạo — `kubectl kustomize overlays/dev` cho ra 0 object `Secret`. Sửa việc "tạo ra"
Secret đó (Secrets Store CSI + SecretProviderClass, B-21's per-service RDS user) chỉ giải quyết
`DB_USER`/`DB_PASSWORD`. Còn lại: **RDS hostname**. Cũ, `overlays/dev/kustomization.yaml` viết
thẳng:
```
DB_URL=jdbc:postgresql://bss-dev-rds.CHANGE_ME.rds.amazonaws.com:5432/customer
```
— một placeholder phải sửa tay **mỗi lần** sau `terraform apply` (hostname RDS gồm 1 chuỗi ngẫu
nhiên AWS sinh ra, không đoán trước được), dễ quên, và dev bị `terraform destroy`/`apply` lại mỗi
ngày (CLAUDE.md §10) — nghĩa là bước sửa tay này lẽ ra phải lặp lại **hằng ngày**.

## Quyết định

**RDS host/port không đi qua ConfigMap (giá trị tĩnh, người viết tay) — đi qua đúng con đường mà
username/password đã đi qua: Secrets Manager → SecretProviderClass → K8s Secret → `secretKeyRef`.**

Terraform (`modules/rds/main.tf`, đã có sẵn từ B-21) vốn đã ghi `host`/`port` (và `dbname` cho
secret riêng từng service) vào **cùng** JSON secret chứa `username`/`password` — chỉ là chưa ai
đọc 2 field đó ra. Việc cần làm chỉ là:

1. Mỗi `SecretProviderClass` (`overlays/dev/secrets/*.yaml`) trích thêm `host`/`port`/`dbname`
   (ngoài `username`/`password`) vào cùng K8s Secret nó sync ra.
2. `application.yml` của cả 4 service đổi từ 1 biến `DB_URL` (URL đầy đủ) sang ghép từ 3 biến:
   `jdbc:postgresql://${DB_HOST:localhost}:${DB_PORT:5432}/${DB_NAME:<default>}`.
3. `overlays/local/kustomization.yaml` (kind) đổi tương ứng: `secretGenerator` giờ có thêm
   `host`/`port`/`dbname` (giá trị tĩnh — `postgres.bss.svc.cluster.local`, biết trước vì đó là
   tên Service Postgres do chính overlay này định nghĩa) thay vì literal `DB_URL` trong
   `configMapGenerator`.

Kết quả: **`overlays/dev/kustomization.yaml` không còn placeholder RDS hostname nào để sửa tay
nữa** — giá trị tự động đúng sau mỗi lần `terraform apply` mới, kể cả khi hostname RDS đổi (ví
dụ: xoá RDS instance rồi tạo lại với tên khác).

## Vì sao không tạo Secret NGAY từ Terraform (`kubernetes_secret` provider)?

Có thể dùng provider `kubernetes` của Terraform để tạo thẳng `Secret` chứa `DB_URL` hoàn chỉnh,
bỏ qua CSI. Không chọn — 2 lý do:
- Terraform chạy từ máy/GitHub Actions runner **ngoài** VPC (RDS ở private subnet, nhưng đây là
  gọi K8s API server, không phải RDS — về lý thuyết khả thi vì API server có public endpoint ở
  dev). Vấn đề thật hơn: Terraform state khi đó sẽ chứa **plaintext password** của mọi service
  (`terraform show`/state file), đúng thứ B-21 vừa cố tránh khi chuyển sang Secrets Manager. CSI
  không bao giờ đưa secret vào Terraform state.
- Không nhất quán với `local`: local dùng `secretGenerator` của chính Kustomize, không có
  Terraform nào chạy. Giữ "Secret luôn tới từ tầng K8s, nội dung khác nhau theo overlay" đơn giản
  hơn "3 cách khác nhau tuỳ môi trường".

## Hệ quả

- ✅ Không còn bước thủ công "copy RDS endpoint từ `terraform output` dán vào YAML" — đúng nguyên
  nhân gốc CLAUDE.md §13 từng liệt kê ("Replace CHANGE_ME... sau khi có RDS hostname").
- ✅ `overlays/local` và `overlays/dev` giờ dùng **chung 1 cơ chế** (Deployment đọc 5 key giống hệt
  nhau từ 1 Secret cùng tên) — chỉ khác nguồn tạo Secret, base Deployment không cần biết.
- ⚠️ Deployment giờ cần mount CSI volume (`overlays/dev/kustomization.yaml` patches) — thêm vì
  Secrets Store CSI chỉ sync Secret khi có Pod thật sự mount SecretProviderClass; quên patch này
  ở overlay nào đó (staging/prod, khi tới lượt) sẽ lại ra đúng lỗi B-20 gốc
  (`CreateContainerConfigError`).
- ⚠️ `staging`/`prod` **chưa** áp dụng lại pattern này (ngoài phạm vi Giai đoạn 5) — vẫn còn
  `CHANGE_ME` cũ ở đó cho tới khi tới lượt triển khai.

## Lựa chọn khác đã cân nhắc

1. **Viết script `render-overlay.sh` đọc `terraform output -json` rồi `sed`/`yq` ghi đè
   `kustomization.yaml` trước mỗi lần apply** — giải quyết được vấn đề, nhưng tạo ra 1 file
   "sinh ra", dễ quên chạy lại, và vẫn phải chạy lại mỗi ngày (dev destroy/apply hằng đêm) — chỉ
   đổi "sửa tay" thành "chạy tay 1 script", không loại bỏ được bước thủ công.
2. **Giữ `DB_URL` một biến, nhưng đọc từ Secret (thay vì ConfigMap)** — kỹ thuật cũng được (SPC
   có thể tổng hợp URL đầy đủ vào 1 `objectAlias`), nhưng JSON secret RDS vốn đã tách sẵn
   host/port/dbname — tổng hợp lại thành 1 chuỗi URL trong SPC rồi lại phải parse ngược nếu cần
   riêng host/port sau này (ví dụ: healthcheck, metrics theo host) là làm phức tạp thêm không cần
   thiết so với giữ 3 biến riêng.

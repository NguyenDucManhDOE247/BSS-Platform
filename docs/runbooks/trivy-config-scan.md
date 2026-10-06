# Rà `trivy config` — Terraform + Kubernetes (Giai đoạn 7, việc 8)

## Kết quả

| Phạm vi | HIGH/CRITICAL trước | HIGH/CRITICAL sau |
|---|---|---|
| `infrastructure/terraform` (5 module + 4 env) | 0 | 0 (đã sạch sẵn — có `#trivy:ignore` inline cho vài rule dev cố tình mở, vd `AVD-AWS-0164` IP public cho subnet dev) |
| K8s overlay `dev`/`staging`/`prod` (`kubectl kustomize \| trivy config`) | 7 (`KSV-0118`, mọi Deployment) | **0** |
| K8s overlay `local` | 11 (7 KSV-0118 + `KSV-0014` LocalStack + 3× `KSV-0109` ConfigMap chứa "secret") | **2** (còn lại, xem mục 3) |

## Đã sửa

**`KSV-0118` (HIGH) × 7 — "Deployment dùng securityContext mặc định, cho phép chạy root"**: cả 7
Deployment base (`admin-console`, `api-gateway`, `billing-service`, `customer-service`,
`order-management`, `product-catalog`, `web-portal`) chỉ có `securityContext` ở CẤP CONTAINER, chưa
có ở CẤP POD (`spec.template.spec.securityContext`). Thêm `runAsNonRoot: true, runAsUser: 1000,
seccompProfile: RuntimeDefault` ở cấp Pod — phòng khi có container KHÁC (initContainer, sidecar)
được thêm sau này mà quên đặt securityContext riêng, Pod vẫn không chạy bằng root theo mặc định.

**`KSV-0109` (HIGH) × 2 — ConfigMap `order-management-config`/`billing-service-config` chứa khóa
trông giống secret (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)**: giá trị là `"test"/"test"` —
hằng số CÔNG KHAI của chính LocalStack (không phải bí mật thật), nhưng trivy quét theo TÊN KHÓA,
không biết giá trị có thật hay không. Chuyển 2 khóa này sang `secretGenerator` riêng
(`order-management-aws-test-credentials`, `billing-service-aws-test-credentials`), gắn bằng patch
(chỉ overlay `local` — dev/staging/prod dùng IRSA thật, không cần khóa nào) — thói quen đúng là
"trông giống secret thì đi qua đường Secret", dù giá trị vô hại.

## Còn lại (2, chấp nhận có ghi chú — không phải bỏ quên)

- `KSV-0014` — container `localstack` chưa `readOnlyRootFilesystem: true`. LocalStack (ảnh cộng
  đồng, không phải service tự viết) cần ghi trạng thái nội bộ ra đĩa lúc chạy; bật cờ này cần khảo
  sát kỹ LocalStack ghi vào những đường dẫn nào để mount đủ `emptyDir` — việc riêng, không chặn
  Giai đoạn 7 (LocalStack chỉ chạy ở kind, không phải rủi ro bảo mật thật trên AWS).
- `KSV-0109` — script khởi tạo `localstack-init` (ConfigMap) có dòng `export AWS_ACCESS_KEY_ID=test`
  bên trong nội dung SHELL SCRIPT (không phải biến môi trường K8s) — cùng lý do như trên (giá trị
  công khai của LocalStack), nhưng đây là **nội dung file script**, không có "đường Secret" tương
  đương hợp lý để chuyển sang (không phải env var). Chấp nhận, có ghi chú.

## Terraform — các rule LOW/MEDIUM chấp nhận có lý do (không phải HIGH, không bắt buộc theo phạm vi
việc 8, ghi lại để tra cứu sau)

34 finding LOW/MEDIUM (0 HIGH/CRITICAL) — toàn bộ đều là tính năng **tốn thêm tiền AWS** khi bật
(KMS customer-managed key cho ECR/RDS/Secrets Manager, VPC Flow Logs, EKS control-plane logging
đầy đủ 5 loại, RDS Performance Insights, tăng backup retention) — đúng tinh thần cost-conscious của
PROJECT.md §10 ("Budget alert $30/tháng cho dev"). Không bật hàng loạt mà không hỏi (PROJECT.md §9).
Việc riêng nếu muốn bật cho `staging`/`prod` — nên làm theo từng module, cân nhắc chi phí cụ thể.

## Đã kiểm chứng

- `kubectl kustomize` cả 4 overlay build sạch sau khi sửa.
- `trivy config --severity HIGH,CRITICAL` chạy lại trên bản render cả 4 overlay — dev/staging/prod
  = 0, local = 2 (đã giải thích ở trên).

# ADR-006 — Staging/prod: giữ 3 cluster riêng, nhưng "ephemeral" (dựng theo buổi, destroy sau)

- **Trạng thái:** Chấp nhận (Accepted)
- **Ngày:** 2026-09-25
- **Giai đoạn:** 6 — CD: dev tự động, promotion staging → prod
- **Liên quan:** ADR-002 (mạng dev), ADR-005 (nguồn sự thật phiên bản), CLAUDE.md §4

## Bối cảnh

Promotion `rc-vX` → staging → `vX` → prod cần **một nơi thật để deploy tới**. `learning/20` (Giai
đoạn 6, mục 5) đưa ra hai hướng cho ngân sách sinh viên:

1. staging & prod là **namespace** `bss-staging`/`bss-prod` trên **cùng một cluster**; hoặc
2. dựng cluster staging/prod **chỉ trong buổi demo rồi destroy**.

Ngoài ra thiết kế gốc là **3 cluster** (CLAUDE.md §4) và người dùng đã xác nhận ở Giai đoạn 0
(2026-09-14): *3 cluster riêng*, ngân sách "thoải mái", mục tiêu là **đề tài nghiên cứu** cần
"hoàn thiện" chứ không phải bài tập môn học.

## Đánh đổi của từng hướng (đã tính, không chỉ liệt kê ưu điểm)

| | Namespace, cùng cluster | 3 cluster chạy 24/7 | **3 cluster, staging/prod ephemeral** |
|---|---|---|---|
| Chi phí | Rẻ nhất | ≈ $44+/ngày cộng dồn (CLAUDE.md §4: dev ~$5 + staging ~$9 + prod ~$30+) | ≈ tỷ lệ số giờ bật: ~3 giờ/buổi ⇒ staging ≈ $1, prod ≈ $4 (ước tính từ số/ngày của CLAUDE.md — kiểm chứng bằng Cost Explorer sau buổi đầu) |
| Giống prod thật (3 AZ, `t3.large`, RDS multi-AZ) | ❌ không kiểm chứng được | ✅ | ✅ (trong lúc bật) |
| Cô lập blast radius / IAM / dữ liệu | ❌ chung node, chung RDS; IRSA + DB + EventBridge phải nhân bản theo namespace | ✅ | ✅ |
| Vừa tài nguyên | ❌ 2×`t3.medium` chỉ ~34 pod tối đa (giới hạn ENI, xem B-22): system+addon ≈ 15 (ước tính) + 3 env × 7 app = 36 > 34 | ✅ | ✅ |
| Chứng minh được thiết kế gốc của đề tài | ❌ | ✅ | ✅ |
| Độ phức tạp vận hành | Thấp | Thấp | Trung bình: mỗi buổi phải dựng lại (~20–25 phút EKS + addon + db-bootstrap) |
| Rủi ro | Prod/staging gây nhiễu dev | Hóa đơn | **Quên destroy** ⇒ hóa đơn |

## Quyết định

**Giữ nguyên Terraform 3 môi trường** và chọn cột thứ ba. Cụ thể:

1. `staging` và `prod` nhận biến `ephemeral` (mặc định `false` — an toàn):
   - `ephemeral = true` ⇒ `deletion_protection = false` (RDS tự bỏ luôn `skip_final_snapshot`
     theo `!deletion_protection` sẵn có trong `modules/rds`) và `secret_recovery_window_days = 0`
     (nếu không, sau `destroy` tên secret bị giữ 7–30 ngày và `apply` lần sau lỗi trùng tên — cùng
     bài học B-37 của dev).
   - `ephemeral = false` ⇒ hành vi cũ (bảo vệ xóa bật) cho ngày nào đó nâng cấp lên chạy thật.
2. **Trạng thái bền nằm ngoài cluster:** ECR + OIDC + role deployer ở `environments/shared`
   (ADR-003), release manifest ở nhánh `deploy-state` (ADR-005). Dựng lại `prod` sau destroy =
   `terraform apply` → `platform-install.sh` → db-bootstrap → chạy lại `cd-prod` bằng
   `workflow_dispatch` (áp `prod.json`); **dữ liệu nghiệp vụ không được giữ** (seed/migration dựng lại).
3. Overlay `staging`/`prod` phải **đồng bộ với `dev`** (chúng đã lạc hậu sau Giai đoạn 4–5: còn
   `DB_URL`, thiếu SecretProviderClass, thiếu IAM `product-catalog`, còn `CHANGE_ME`) — nếu không
   thì `rc-v0.1.0` không thể chạy trọn. HTTP-only cho tới khi có domain (memory Giai đoạn 0:
   domain/ACM/HTTPS để sau), giống dev (B-23).
4. Teardown: `scripts/teardown.sh` giữ nguyên xác nhận gõ `destroy-prod`.

## Hệ quả

- ✅ Chứng minh được thiết kế 3 cluster/HA/multi-AZ với chi phí ≈ số giờ dùng thật.
- ✅ Không phải nhân bản IRSA/DB/EventBridge theo namespace (giữ nguyên module hiện có).
- ⚠️ **Prod không chạy 24/7** ⇒ không đo được SLO dài hạn, không thấy các sự cố chỉ xuất hiện
  sau nhiều ngày. Ghi rõ trong tài liệu đề tài; SLO/burn-rate (Giai đoạn 7) được chứng minh trên
  dev + cluster prod trong buổi demo.
- ⚠️ Mỗi buổi tốn thêm ~25 phút dựng lại + phải nhớ destroy. Giảm rủi ro: budget alert
  (`bootstrap-aws.sh`), gán tag `Environment` để lọc trong Cost Explorer, và checklist cuối buổi
  trong `docs/runbooks/cd-staging-prod-demo.md`.
- ⚠️ `ephemeral = true` cho **prod** chỉ hợp lý vì đây là dự án học tập/đề tài; với prod thật phải
  để `false`. Biến này tách "chính sách" khỏi "code" để việc đó là một dòng `tfvars`, không phải sửa module.

## Điều kiện xem lại

- Ngân sách bị siết mạnh ⇒ hướng 1 (namespace) kèm ADR mới về cách nhân bản IRSA/DB/bus theo
  namespace và nâng node group (hoặc Karpenter) cho đủ pod.
- Có nhu cầu demo prod liên tục nhiều ngày (vd. bảo vệ đề tài) ⇒ bật `ephemeral = false` đúng trong
  khoảng đó rồi destroy sau.

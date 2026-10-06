# ADR-006 — Staging/prod: giữ 3 cluster riêng, nhưng "ephemeral" (dựng theo buổi, destroy sau)

- **Trạng thái:** Chấp nhận (Accepted)
- **Ngày:** 2026-09-25
- **Giai đoạn:** 6 — CD: dev tự động, promotion staging → prod
- **Liên quan:** ADR-002 (mạng dev), ADR-005 (nguồn sự thật phiên bản), PROJECT.md §4

## Bối cảnh

Promotion `rc-vX` → staging → `vX` → prod cần **một nơi thật để deploy tới**. `learning/20` (Giai
đoạn 6, mục 5) đưa ra hai hướng cho ngân sách sinh viên:

1. staging & prod là **namespace** `bss-staging`/`bss-prod` trên **cùng một cluster**; hoặc
2. dựng cluster staging/prod **chỉ trong buổi demo rồi destroy**.

Ngoài ra thiết kế gốc là **3 cluster** (PROJECT.md §4) và người dùng đã xác nhận ở Giai đoạn 0
(2026-09-14): *3 cluster riêng*, ngân sách "thoải mái", mục tiêu là **đề tài nghiên cứu** cần
"hoàn thiện" chứ không phải bài tập môn học.

## Đánh đổi của từng hướng (đã tính, không chỉ liệt kê ưu điểm)

| | Namespace, cùng cluster | 3 cluster chạy 24/7 | **3 cluster, staging/prod ephemeral** |
|---|---|---|---|
| Chi phí | Rẻ nhất | ≈ $44+/ngày cộng dồn (PROJECT.md §4: dev ~$5 + staging ~$9 + prod ~$30+) | ≈ tỷ lệ số giờ bật: ~3 giờ/buổi ⇒ staging ≈ $1, prod ≈ $4 (ước tính từ số/ngày của PROJECT.md — kiểm chứng bằng Cost Explorer sau buổi đầu) |
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

## Ràng buộc kèm theo: EKS public endpoint ↔ runner của GitHub

PROJECT.md §10 yêu cầu endpoint API của EKS **giới hạn CIDR** ở prod. Nhưng CD chạy trên runner do GitHub
cấp (`ubuntu-latest`) — không có IP cố định (hàng nghìn dải, đổi liên tục; EKS chỉ nhận ≤ 40 CIDR). Với danh
sách chặt, `kubectl` trong Actions **timeout**. Không có lựa chọn "vừa chặt vừa tự động" miễn phí:

| Lựa chọn | Đánh đổi |
|---|---|
| A. `0.0.0.0/0` **chỉ trong buổi demo** rồi destroy | API vẫn cần chữ ký IAM + RBAC (không ẩn danh) và tồn tại vài giờ; nhưng mở cho Internet và vi phạm chữ nghĩa của §10 |
| B. Self-hosted runner trong VPC + endpoint private | Đúng chuẩn production; tốn thêm EC2 + vận hành runner |
| C. Deploy bằng tay từ máy có IP trong danh sách | Giữ endpoint chặt; mất tự động hóa + cổng duyệt của GitHub cho bước deploy |

**Quyết định của ADR này:** mặc định trong code **giữ danh sách chặt** (không đổi hành vi hiện có); dùng A là một
**ngoại lệ có chủ đích, do chủ repo tự bật** trong `terraform.tfvars` cho buổi ephemeral và phải được nêu rõ trong
tài liệu đề tài. Với prod chạy thật, dùng B. Chi tiết và lệnh: `docs/runbooks/cd-staging-prod-demo.md` §4.

## Ràng buộc kèm theo: quota vCPU EC2 (8) quyết định cỡ prod

Tài khoản mới có quota EC2 "Running On-Demand Standard" = **8 vCPU** (tính cộng dồn mọi cluster). AWS **từ chối**
tăng lên 32 (2026-09-28, case `CASE_CLOSED`: chưa đủ lịch sử sử dụng; xin lại được sau chu kỳ billing kế tiếp).
Thiết kế prod cũ (CPU requests backend 500m ⇒ ~8.15 vCPU ⇒ 5 node = 10 vCPU) vì vậy không dựng được.

| Lựa chọn | Đánh đổi |
|---|---|
| A. Chờ quota | Không đổi thiết kế, nhưng phụ thuộc AWS (ngày → tuần), prod chưa được kiểm chứng |
| B. Hạ replicas | Lệch thiết kế HA (3 replica, PDB `minAvailable: 2`) |
| C. **Hạ CPU `requests` backend 500m → 250m (base), prod 4 node** | Giữ 3 replica/PDB/3 AZ; 500m là số đoán lúc scaffold, staging/dev đo thật ~4% CPU. Đổi lại: 2 node chạm 91–93% requests, HPA scale-out sớm hơn nhưng không còn chỗ (max 4 = đúng quota) |
| D. Thêm node Spot (quota Spot riêng, 8 vCPU) | Phải sửa Terraform; Spot có thể bị thu hồi giữa buổi |

**Quyết định (PR #162): C.** Kiểm chứng thật ngày 2026-09-28: `rc-v0.1.1` qua staging (14 Pod) → `v0.1.1` lên prod
(20 Pod `Running`, smoke PASS, 4 node `Ready`) rồi destroy. Vì đổi manifest nên phải tag rc mới và chạy lại staging
(cd-prod đòi cùng commit với rc). Bài học vận hành: quota chỉ bị kiểm khi EC2 *khởi chạy* nên `terraform plan` không báo trước;
mọi đợt tăng số node/CPU requests phải kiểm quota trước (runbook §1b/§1c).

## Điều kiện xem lại

- Ngân sách bị siết mạnh ⇒ hướng 1 (namespace) kèm ADR mới về cách nhân bản IRSA/DB/bus theo
  namespace và nâng node group (hoặc Karpenter) cho đủ pod.
- Có nhu cầu demo prod liên tục nhiều ngày (vd. bảo vệ đề tài) ⇒ bật `ephemeral = false` đúng trong
  khoảng đó rồi destroy sau.
- Quota vCPU EC2 được nâng (≥ 12) ⇒ cân nhắc trả CPU requests prod về mức dư địa hơn và `max_size` 5–6 (xem mục quota ở trên).

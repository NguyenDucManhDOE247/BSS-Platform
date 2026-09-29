# ADR-010 — Karpenter: làm thật ở dev (Spot), staging/prod giữ node group cố định

- **Trạng thái:** Chấp nhận (Accepted) — chủ repo chọn "làm Karpenter thật" 2026-09-29. **Thay thế
  [ADR-007](ADR-007-karpenter.md)** (ADR-007 giữ nguyên làm lịch sử lý do lúc đó).
- **Ngày:** 2026-09-29
- **Giai đoạn:** dọn nợ Giai đoạn 8 (sau Giai đoạn 9)

## Bối cảnh

ADR-007 (2026-09-27) chọn KHÔNG bật Karpenter vì ADR-006 (cluster ephemeral) đã chiếm phần lớn lợi ích
tiết kiệm Spot. Khi đọc lại ở đợt dọn nợ, chủ repo muốn làm thật. Có 3 thay đổi so với lúc viết ADR-007:

1. **Bằng chứng thật về giới hạn sức chứa:** load test GĐ8 thấy Pod `Pending` vì hết chỗ trên 2 node
   ("0/2 nodes are available: Insufficient cpu/memory"), và GĐ9 việc 7 phải **tăng tay** dev 2 → 3 node
   để có chỗ cho Keycloak. Cả 2 lần đều là việc một autoscaler làm được mà không cần người.
2. **Quota Spot tách riêng:** tài khoản có 8 vCPU On-Demand **và** 8 vCPU Spot (L-34B43A08). Node Spot
   do Karpenter tạo không ăn vào quota On-Demand vốn đang là trần cứng của prod (ADR-006).
3. **Mục tiêu học:** Karpenter là 1 trong các công nghệ mới với chủ repo ghi ở hồ sơ học tập — đọc về
   nó khác hẳn tự thấy node sinh ra/biến mất theo tải.

## Quyết định

**Bật Karpenter 1.14.1 ở dev; staging/prod giữ managed node group cố định.**

| | dev | staging / prod |
|---|---|---|
| Managed node group | 2 × t3.medium (hệ thống + controller Karpenter) | cố định (3 / 4 × t3.large) như ADR-006 |
| Karpenter | NodePool `default`: Spot trước, On-Demand dự phòng; t/m/c thế hệ > 2, 2–4 vCPU; trần **8 vCPU** (= quota Spot); gom node thừa sau 1 phút, mỗi lúc thu 1 node | không cài |
| Vì sao | nơi tải thay đổi (load test, chaos, thêm service) và chạy lâu nhất trong ngày | chạy 1 buổi, cần **số đo ổn định, lặp lại được** cho promotion; prod đã vừa khít quota On-Demand |

Chi tiết triển khai:
- **IAM:** `modules/platform-iam/karpenter.tf` dịch sát template CloudFormation chính thức của đúng
  v1.14.1 (controller role IRSA + 3 inline policy, hàng đợi SQS interruption + 5 rule EventBridge). Node
  Karpenter dùng **chung role** với managed node group → đã có access entry, không cần thêm.
- **Cài đặt:** bước 6/6 của `scripts/platform-install.sh` (chỉ chạy khi Terraform output
  `karpenter_role_arn` khác null), rồi `platform/networking/karpenter-nodepool.yaml`.
- **Destroy:** node Karpenter **không nằm trong state Terraform** (như ALB) → `scripts/teardown.sh` xóa
  NodePool và chờ NodeClaim hết TRƯỚC `terraform destroy`, cuối cùng in lệnh kiểm EC2 mồ côi theo tag
  `karpenter.sh/nodepool`.

## Hệ quả

- ✅ Dev không còn phải tăng/giảm node bằng tay; tải vượt sức chứa → node Spot mới trong ~1 phút.
- ✅ Giá node Spot thấp hơn On-Demand (thường 60–70%) cho phần tải dao động.
- ⚠️ Spot có thể bị AWS thu hồi (báo trước 2 phút) → Karpenter nhận cảnh báo qua SQS và thay node; Pod
  trên node đó khởi động lại (1 replica ở dev → gián đoạn ngắn, giống bài chaos GĐ8).
- ⚠️ Thêm 1 thành phần phải giữ đồng bộ version: chart ↔ IAM policy (cùng kiểu với ALB Controller).
- ⚠️ Quên xóa NodePool trước destroy = EC2 mồ côi tiếp tục tính tiền — đã đưa vào `teardown.sh`.

## Kết quả đo thật

(điền sau buổi chạy trên dev EKS — thời gian từ Pod `Pending` tới node `Ready`, loại máy + giá Spot
Karpenter chọn, thời gian gom node khi hết tải, và load test GĐ8 chạy lại.)

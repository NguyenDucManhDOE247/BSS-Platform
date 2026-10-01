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

## Kết quả đo thật (dev EKS, 2026-09-29)

**Tự thêm node khi thiếu chỗ.** Managed node group 2 × t3.medium đủ cho 8 Pod ứng dụng (Boot 3.5 dùng ít RAM
hơn — node 63–76%). Cài kube-prometheus-stack làm Pod thiếu chỗ → Karpenter tạo node: NodeClaim tạo →
launched +5s → registered +26s → **Ready +39s**.

**Lỗi thật #1 — Spot không dùng được, âm thầm rơi xuống On-Demand.** Node đầu là `t3a.medium` On-Demand.
Log: `AuthFailure.ServiceLinkedRoleCreationNotPermitted` — tài khoản chưa từng dùng Spot nên chưa có
`AWSServiceRoleForEC2Spot`, và controller (đúng policy chính thức) không được tạo role cấp tài khoản.
Karpenter vẫn "chạy" nhưng đắt gấp đôi. Sửa: `scripts/bootstrap-aws.sh` bước 3 tạo role (1 lần/tài
khoản). Sau khi tạo phải chờ **cache "offering không khả dụng" ~3 phút** của Karpenter hết hạn; lần tạo
lại kế tiếp ra **`t3.medium` Spot, Ready +36s**. Giá lúc đo: Spot **$0.0246/h** vs On-Demand **$0.0528/h**
(−53%).

**Tải 200 → 700 req/s** (dựng lại đúng lần 2 của GĐ8, WAF tạm gỡ để rate-limit không chặn máy đo):

| | GĐ8 (2 node cố định) | Có Karpenter (trần 8 vCPU Spot) |
|---|---|---|
| Request phục vụ | 58.926 | **139.781** (×2.4) |
| p95 | 8,55 s | **3,66 s** |
| Lỗi | 5,47% | **7,9%** (tệ hơn) |
| dropped_iterations | 57.948 | 42.469 |

HPA đẩy api-gateway lên 12, product-catalog lên 8 → Pod `Pending` → Karpenter thêm tới **4 NodeClaim
trong ~1 phút** (3 → 6 node), chọn máy **nhỏ nhất đủ chỗ** (`t3.small`, `t8i.small` Spot — 2 vCPU/2 GiB)
rồi dừng ở trần NodePool 8 vCPU ("could not schedule pod") — 10 Pod vẫn `Pending`. Trần sức chứa **dời
lên** nhưng vẫn bị quota chặn. Tỉ lệ lỗi CAO HƠN chưa được giải thích — giả thuyết chưa kiểm: Pod mới nhận
tải khi JVM còn lạnh; node 2 GiB quá chật cho Pod 512Mi. **Manh mối có bằng chứng (bổ sung sau):** kênh
Discord nhận alert `BssPodCrashLooping` cho 2 Pod `api-gateway` ("restarting repeatedly") đúng trong lúc
đo — Pod gateway khởi động lại dưới tải là nguồn lỗi rất có thể. Cluster đã destroy nên chưa biết lý do
restart (OOMKilled hay liveness fail khi CPU bão hòa). Việc tiếp: đo lại, xem `kubectl describe pod`
(`Last State`), và thử `instance-memory` ≥ 4 GiB.

> **Đã giải thích + sửa (2026-10-01, đo lại đúng bậc 200→700, chi tiết `docs/labs/07-load-test-dev.md` mục 2c).**
> Không phải OOMKilled và không phải node 2 GiB: (A) **liveness/readiness timeout mặc định 1s** — CPU bão hòa →
> kubelet giết Pod gateway đang phục vụ (`exit 143`) → **502**; (B) **hết kết nối RDS** — 8 Pod product-catalog ×
> HikariCP giữ sẵn 10 kết nối trên `db.t3.micro` (~70 kết nối) → Pod mới chết khi khởi động, Pod cũ trả **500**.
> Sửa probe timeout + pool 5/min-idle 1 → **0% lỗi ở 3 lần đo liền**, 0 restart. Thông lượng/p95 giữa các lần dao
> động quá lớn (72k–170k request cùng cấu hình) để kết luận gì thêm — máy đo nằm ngoài region.
> Bonus từ cùng buổi: PDB `minAvailable: 1` + 1 replica chặn Karpenter gom node ở dev → overlay dev `maxUnavailable: 1`.

**Gom node khi hết tải:** ~6 phút sau khi k6 dừng (chờ HPA thu Pod), Karpenter xóa 2/4 NodeClaim. Log có
cảnh báo `TopologySpreadConstraint` dạng preferred có thể cản việc gom.

**Lỗi thật #2 — teardown.** Bước xóa NodePool hết 5 phút mà 2 node vẫn còn → destroy xóa cluster, 2 EC2
mồ côi giữ security group của cluster → subnet + VPC treo tới khi terminate tay + xóa SG. Nghi vấn chính
(log không đủ để khẳng định): drain bị PDB `minAvailable: 1` của service 1 replica chặn (bài học GĐ8).
Sửa: NodePool `terminationGracePeriod: 10m`; `teardown.sh` xóa PDB trước, và nếu vẫn còn thì terminate
theo tag (cluster + nodepool) TRƯỚC destroy. Cũng buổi này: 3 EBS volume của PVC monitoring mồ côi →
`teardown.sh` xóa PVC trước destroy. `tools/ops/orphan_finder.py` là thứ bắt được cả hai.

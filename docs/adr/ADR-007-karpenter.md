# ADR-007 — Karpenter: không áp dụng ở giai đoạn hiện tại

- **Trạng thái:** ~~Chấp nhận~~ → **Bị thay thế (Superseded) bởi [ADR-010](ADR-010-karpenter-lam-that-o-dev.md)** 2026-09-29 — chủ repo chọn làm Karpenter thật ở dev. Giữ file này làm lịch sử lý do.
- **Ngày:** 2026-09-27
- **Giai đoạn:** 8 — Reliability, load test, tài liệu, demo

## Bối cảnh

CLAUDE.md §2 chọn "EKS Managed Node Groups + Karpenter cho workload" ngay từ đầu, với lý do
"Karpenter tự provision spot rẻ hơn ~70%". Giai đoạn 8, việc 3 yêu cầu: bật Karpenter thật (ưu tiên
Spot) **hoặc** ghi ADR giải thích vì sao không dùng. Trước khi quyết định, cần đối chiếu lại lý do
ban đầu với thực tế đã thay đổi rất nhiều kể từ khi CLAUDE.md được viết (2026-05-22):

1. **ADR-006** (Giai đoạn 6) đã chốt staging/prod là **ephemeral** — dựng theo buổi, destroy ngay
   sau, không chạy 24/7. Lợi ích lớn nhất của Karpenter (tự co giãn node theo giờ, tránh trả tiền
   node nhàn rỗi ban đêm) **đã đạt được bằng cách khác** (destroy triệt để) — ephemeral cluster
   không có "ban đêm nhàn rỗi" để tối ưu, vì nó không tồn tại ngoài giờ làm việc.
2. Quy mô hiện tại: **7 service, 2 node t3.medium (dev) / t3.large (staging/prod)** — managed node
   group với `desired_size` cố định + Cluster Autoscaler (nếu cần) đã đủ; Karpenter được thiết kế
   cho bài toán bin-packing hàng chục/hàng trăm node với workload đa dạng, chưa phải bài toán ở đây.
3. Karpenter cần thêm: `NodePool` + `EC2NodeClass` (2 CRD phải viết đúng), interruption queue (SQS)
   + IAM role riêng để xử lý Spot bị thu hồi, và **thay thế hoàn toàn** managed node group hiện có
   (không chạy song song dễ dàng) — đây là thay đổi kiến trúc không nhỏ, không phải bật 1 cờ.
4. Rủi ro Spot cho **RDS/stateful workload**: Karpenter tự thu hồi node Spot bất kỳ lúc nào (báo
   trước 2 phút) — chấp nhận được cho backend stateless (đã có PDB + ≥2 replica ở staging/prod),
   nhưng cộng thêm một lớp bất định vào đúng lúc dự án cần **số liệu load-test ổn định, tái lập
   được** (Giai đoạn 8, việc 1) — Spot interruption giữa lúc đo k6 sẽ làm nhiễu kết quả ngưỡng rps.

## Các phương án đã cân nhắc

| # | Phương án | Lợi ích | Chi phí thực hiện | Ghi chú |
|---|---|---|---|---|
| A | Bật Karpenter thật + `NodePool` ưu tiên Spot | Tiết kiệm thêm ~70% giá node lúc cluster đang bật | Cao: 2 CRD mới, interruption queue + IAM, thay managed node group, học đường cong mới | Giá trị học tốt nhưng lệch trọng tâm Giai đoạn 8 (reliability + tài liệu, không phải thêm hạ tầng mới) |
| B | Giữ managed node group cố định (hiện tại) | Đơn giản, đã ổn định qua 7 giai đoạn, số liệu load-test không bị nhiễu bởi Spot interruption | Không có (đã làm) | **Chọn phương án này** |
| C | Managed node group + Cluster Autoscaler (không phải Karpenter) | Co giãn số node theo tải mà không đổi kiến trúc lớn | Trung bình: thêm 1 addon + IAM | Cân nhắc lại khi thật sự cần co giãn tự động (vd. nếu bỏ ephemeral, chạy 24/7) |

## Quyết định

**Chọn phương án B — giữ Managed Node Group cố định, KHÔNG bật Karpenter ở giai đoạn hiện tại.**
`platform/networking/` giữ nguyên file values Karpenter đã có sẵn từ scaffold ban đầu (không xóa —
có giá trị tham khảo), nhưng **không cài đặt** (không có trong `scripts/platform-install.sh`).

Lý do chính: giá trị tiết kiệm chi phí của Karpenter đã bị **ADR-006 (ephemeral cluster) chiếm mất
phần lớn** — cluster không chạy đủ lâu để chênh lệch giá Spot/On-Demand tích lũy thành số tiền đáng
kể, trong khi độ phức tạp thêm vào (2 CRD, interruption handling, thay thế node group đang hoạt
động ổn định) có rủi ro cao hơn giá trị học được ở đúng giai đoạn này (CLAUDE.md §2 "không
over-engineer").

**Khi nào nên quay lại quyết định này:** nếu dự án chuyển sang chạy dev **24/7 không destroy**
(vd. để demo cho nhiều người xem lâu dài), hoặc nếu node count thật sự tăng (nhiều service hơn,
cần bin-packing thông minh hơn desired_size cố định) — lúc đó chi phí node nhàn rỗi mới đủ lớn để
đáng đánh đổi độ phức tạp của Karpenter.

## Hệ quả

- ✅ Không thêm CRD/IAM/addon mới ngay trước khi làm load test (Giai đoạn 8 việc 1) — số liệu rps
  threshold đo được không bị nhiễu bởi Spot interruption ngẫu nhiên.
- ✅ Giữ đúng nguyên tắc "sửa/thêm theo nhu cầu của bước đang làm" (`learning/20` mục 0.2) — Karpenter
  không phải nhu cầu của Giai đoạn 8.
- ⚠️ CLAUDE.md §2 dòng "Karpenter tự provision spot rẻ hơn ~70%" nay là **thông tin lịch sử của
  quyết định ban đầu**, không phải trạng thái hiện tại — CLAUDE.md §13 (cập nhật cùng đợt với ADR
  này) trỏ sang ADR-007 để tránh đọc nhầm là "đã làm".
- ⚠️ `platform/networking/karpenter-nodepool.yaml` (còn lại từ scaffold ban đầu) trở thành tài liệu
  tham khảo "đã cân nhắc nhưng chưa dùng", không phải cấu hình đang chạy — không xóa để giữ giá trị
  học tập, nhưng không mong đợi nó hoạt động nếu áp dụng thẳng (chưa kiểm chứng với version hiện tại
  của EKS/addon khác, và thiếu IAM/interruption queue đi kèm — xem mục "Các phương án" ở trên).

## Tự kiểm tra

Vì sao "ephemeral cluster" (ADR-006) làm giảm giá trị của Karpenter nhiều hơn là làm tăng nó? Gợi ý:
so sánh đường cong tiết kiệm chi phí của Karpenter (tích lũy theo **thời gian cluster chạy liên
tục**) với mô hình "bật vài giờ mỗi buổi học rồi destroy sạch" — điểm hòa vốn về công sức thiết lập
nằm ở đâu?

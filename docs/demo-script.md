# Demo video script — 5 phút (Giai đoạn 8, việc 6)

**Kịch bản:** deploy → phá → hồi phục. Quay màn hình (OBS Studio / Windows Game Bar), giọng nói
tiếng Việt (giữ thuật ngữ kỹ thuật tiếng Anh, giống văn phong `learning/`). Ghi hình **sau khi** đã
tự tay chạy qua toàn bộ kịch bản ít nhất 1 lần (Lab 07, Lab 08) — video này kể lại một câu chuyện
đã kiểm chứng thật, không phải lần thử đầu tiên trên camera.

Chuẩn bị trước khi bấm ghi: dev EKS đã `terraform apply` xong, 7 Pod `Running`, 1 terminal
`kubectl -n bss get pods -w` và 1 terminal `kubectl -n bss get hpa -w` mở sẵn ở cửa sổ khác (cắt
cảnh sang khi cần, không cần chia đôi màn hình suốt video).

## Cảnh 1 — Giới thiệu (0:00 – 0:40)

- Mở bằng kiến trúc tổng thể (dùng `docs/architecture/bss_eks_architecture.png` hoặc
  `interactive_architecture.html`), nói 1 câu: đây là BSS (Business Support System) chuẩn TM Forum,
  chạy trên EKS thật, tự dựng bằng Terraform.
- Nêu bối cảnh ngắn: nhận lại từ thầy, tự kiểm chứng lại toàn bộ, hoàn thành 8 giai đoạn — không
  cần kể chi tiết từng bug, chỉ 1-2 câu tạo ngữ cảnh.

## Cảnh 2 — Deploy (0:40 – 1:40)

- Chạy `kubectl -n bss get pods` — cho thấy 7 Pod `Running`.
- Mở trình duyệt: `http://<ALB-DNS>` — trang `web-portal`, xem danh sách gói cước (Plans).
- Đặt 1 đơn hàng thật trên UI → chuyển sang trang Bills → hóa đơn xuất hiện (poll tự động), có VAT
  10% đúng — đây là bằng chứng chuỗi `order-management → outbox → EventBridge → SQS →
  billing-service` chạy đúng đầu-cuối trên hạ tầng thật.

## Cảnh 3 — Load test tìm ngưỡng (1:40 – 2:40)

- Cắt sang terminal đã chạy sẵn `k6 run tests/load/dev-threshold.js` (chạy trước, tua nhanh phần
  chờ) — cho thấy bảng tổng kết k6 (p95, checks) + terminal `get hpa -w` bên cạnh với `REPLICAS`
  tăng dần.
- 1 câu thoại: "ở mức X req/s, p95 vượt 500ms — đây là ngưỡng đo được, không phải áng chừng" (điền
  X từ Lab 07 mục 2 sau khi đã đo thật).

## Cảnh 4 — Phá (2:40 – 3:50)

Chọn **1 trong 2** kịch bản dưới đây làm cảnh "phá" chính (kịch bản A trực quan hơn cho video):

**A — Xóa Pod ngẫu nhiên (trực quan, nhanh):**
```bash
./scripts/chaos-delete-pod.sh bss order-management
```
Quay song song: terminal `get pods -w` (thấy Pod cũ `Terminating`, Pod mới `Pending → Running`) +
terminal script (đang bắn request nền, in số liệu recovery cuối cùng). Nói rõ: "Pod bị xóa, nhưng
vì có ≥2 replica + PodDisruptionBudget, 0 request bị mất" (đọc số thật từ output script).

**B — Drain node (ấn tượng hơn về quy mô, chậm hơn ~3 phút):**
```bash
./scripts/chaos-drain-node.sh
```
Quay `get pods -o wide -w` — thấy TOÀN BỘ Pod trên 1 node chuyển `Terminating` rồi mọc lại ở node
còn lại. Nói rõ: "đây mô phỏng AWS thu hồi node hoặc bảo trì — PodDisruptionBudget đảm bảo không
xuống dưới số Pod tối thiểu trong lúc di dời."

## Cảnh 5 — Hồi phục & xác nhận (3:50 – 4:40)

- Quay lại trình duyệt: đặt thêm 1 đơn hàng nữa **ngay sau khi chaos vừa chạy xong** — hóa đơn vẫn
  ra đúng, chứng minh hệ thống đã hồi phục hoàn toàn, không chỉ "Pod Running" mà nghiệp vụ thật vẫn
  đúng.
- Chạy `python tools/ops/health_check.py --mode cluster` (hoặc `--mode local` nếu đã port-forward)
  — bảng UP/DOWN cho cả 5 service, tất cả `UP`.

## Cảnh 6 — Kết & dọn dẹp (4:40 – 5:00)

- 1 câu tổng kết: những gì đã chứng minh được (capacity đo bằng số thật, tự phục hồi có bằng chứng,
  không phải chỉ "code trông đúng").
- Cảnh cuối: `terraform destroy` bắt đầu chạy (không cần quay hết, chỉ vài giây đầu) — nhấn mạnh kỷ
  luật "không để cluster chạy qua đêm" (CLAUDE.md §10 Cost).

## Sau khi quay

- Cắt dựng bằng bất kỳ tool nào quen thuộc (kể cả cắt thô, không cần hiệu ứng — nội dung kỹ thuật
  quan trọng hơn hình thức).
- Đăng kèm mô tả video: link repo, link `docs/ROADMAP.md`, link bài blog (`docs/blog-post-draft.md`
  sau khi đăng chính thức).
- Cập nhật `README.md` (mục Project status hoặc thêm mục "Demo") với link video khi có.

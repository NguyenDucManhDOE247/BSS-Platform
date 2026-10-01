# Demo video script — 5 phút (viết GĐ8, cập nhật cho `v2.0.0` ngày 2026-10-01)

**Kịch bản:** sản phẩm thật (2 website) → deploy trên AWS → tải → phá → hồi phục. Quay màn hình (OBS Studio /
Windows Game Bar), giọng nói tiếng Việt (giữ thuật ngữ kỹ thuật tiếng Anh, giống văn phong `learning/`). Ghi hình
**sau khi** đã tự tay chạy qua toàn bộ kịch bản ít nhất 1 lần — video kể lại một câu chuyện đã kiểm chứng thật,
không phải lần thử đầu tiên trên camera.

> ⚠️ **Vì sao cảnh trình duyệt quay trên kind, không trên AWS.** Từ `v2.0.0`, đặt hàng cần đăng nhập
> (Keycloak + PKCE), mà PKCE cần `crypto.subtle` — trình duyệt chỉ cấp trong *secure context* (HTTPS hoặc
> `*.localhost`). AWS hiện chỉ có HTTP qua DNS của ALB (B-23, chờ domain) nên **2 website trên AWS mở được nhưng
> không đăng nhập được**. Bản kịch bản GĐ8 cũ (mở `http://<ALB-DNS>` rồi đặt hàng) không còn chạy. Cách làm đúng:
> cảnh sản phẩm quay trên kind (`http://bss.localhost`), cảnh hạ tầng quay trên dev EKS. Nói thẳng điều này trong
> video — đó là một quyết định có lý do (ADR-008 QĐ 7–8), không phải chỗ cần giấu.

**Chuẩn bị (2 buổi quay riêng là được, ghép lúc dựng):**
- **kind** ($0): `docs/SETUP.md` / `learning/19` phần 2 → `e2e-kind.sh` PASS. Mở sẵn 2 cửa sổ trình duyệt:
  thường cho khách, **ẩn danh** cho admin (`admin1`/`admin1pass`, chỉ tồn tại ở local).
- **dev EKS** (💰 ~$0.3–0.4/giờ — destroy ngay sau khi quay): `make ENV=dev tf-apply` → platform-install →
  db-bootstrap → **CD — dev** xanh. Mở sẵn terminal `kubectl -n bss get pods -w` và `kubectl -n bss get hpa -w`.

## Cảnh 1 — Giới thiệu (0:00 – 0:30)

- Kiến trúc tổng thể (`docs/architecture/bss_eks_architecture.png`): BSS chuẩn TM Forum — 4 microservice
  Spring Boot + gateway + 2 website React + Keycloak, trên EKS dựng bằng Terraform, CI/CD bằng GitHub Actions OIDC.
- 1 câu bối cảnh: nhận scaffold từ thầy, kiểm chứng lại từ đầu, đưa lên chạy thật qua 10 giai đoạn.

## Cảnh 2 — Sản phẩm: 2 website đồng bộ qua cùng backend (kind, 0:30 – 1:50)

1. **Khách** (`http://bss.localhost`): bấm **Đăng ký** → trang Keycloak → quay về đã đăng nhập → **Hồ sơ**: điền
   tên + SĐT → trạng thái *chờ duyệt*.
2. Vào **Gói cước** → chọn gói → trang giải thích *chưa được duyệt*, **không có nút mua** (backend cũng chặn: 422).
3. **Admin** (cửa sổ ẩn danh, `http://bss.localhost/admin/`): **Khách hàng** → lọc *chờ duyệt* → **Duyệt**.
4. Quay lại khách, tải lại trang gói → **Xác nhận đăng ký** → *Đơn hàng của tôi* có 1 đơn → *Hóa đơn* hiện sau vài
   giây (trang tự làm mới 5s) với VAT 10%. Câu thoại: "đơn và hóa đơn là 2 service khác nhau, nối bằng sự kiện qua
   EventBridge → SQS — nên hóa đơn đến *sau* vài giây, đó là eventual consistency, không phải lỗi."
5. **Admin**: **Dashboard** có số + doanh thu → trang khách → **Đơn** / **Hóa đơn** của đúng khách vừa mua.
6. (Tùy chọn, 10 giây) Admin sửa giá 1 gói → web khách đổi giá ngay; đơn cũ giữ giá lúc mua.

Câu chốt: "Khách khác gọi hóa đơn này nhận **404**, không phải 403 — để không lộ việc hóa đơn đó tồn tại."

## Cảnh 3 — Deploy trên AWS (dev EKS, 1:50 – 2:30)

- Actions → **CD — dev**: quay run xanh (plan → build image thiếu → apply 8 image → rollout → drift → smoke).
- `kubectl -n bss get pods` — đủ Pod `Running` (gồm Keycloak).
- `./scripts/smoke.sh dev` — PASS **có token Keycloak thật** (lấy qua port-forward vì Keycloak không mở ra ALB).
- 1 câu: "Không có AWS access key nào trong GitHub — CI nhận quyền tạm qua OIDC, mỗi môi trường một role."

## Cảnh 4 — Tải: trần thật nằm ở đâu (2:30 – 3:10)

- Cắt sang `k6 run tests/load/dev-threshold.js` đã chạy sẵn (tua nhanh) + `get hpa -w`.
- Số thật (dev EKS, `docs/labs/07-load-test-dev.md` + ADR-010): 2 node cố định ổn tới ≥150 req/s (p95 432 ms,
  0% lỗi); 200→700 req/s thì vỡ (p95 8.55 s) vì **hết chỗ đặt Pod** (`kubectl describe pod` → `Insufficient cpu`).
  Bật Karpenter: phục vụ **gấp 2,4 lần** request, p95 3.66 s — nhưng lỗi 7,9% (chưa giải thích — nói thẳng).

## Cảnh 5 — Phá & hồi phục (3:10 – 4:30)

**A — Xóa Pod (trực quan, nên dùng):**
```bash
./scripts/chaos-delete-pod.sh bss order-management
```
Quay `get pods -w` (Pod cũ `Terminating`, Pod mới `Pending → Running`) + output script. Số thật (lab 08): hồi phục
~21–22 s dù mấy replica; **1 replica: 9/26 request lỗi, 2 replica: 0/56** — "cùng thời gian hồi phục, trải nghiệm
khác hẳn: đó là lý do staging/prod chạy ≥2 replica."

**B — Drain node (bài học sâu, cần giải thích):** `./scripts/chaos-drain-node.sh <node>` — với 1 replica, PDB
chặn evict hoàn toàn (`ALLOWED DISRUPTIONS: 0`) **dù còn node trống**. Chi tiết cách quay: `docs/labs/08-chaos-engineering.md`.

Sau khi phá: `./scripts/smoke.sh dev` lại → PASS (nghiệp vụ thật chạy, không chỉ "Pod Running").

## Cảnh 6 — Kết & dọn dẹp (4:30 – 5:00)

- Tổng kết: capacity đo bằng số, tự phục hồi có bằng chứng, 2 website + auth thật — "không phải code trông đúng".
- Cảnh cuối: `make ENV=dev tf-destroy` bắt đầu chạy, rồi `python tools/ops/orphan_finder.py` → "Không còn tài
  nguyên BSS tính tiền nào" — kỷ luật không để cluster chạy qua đêm.

## Sau khi quay

- Cắt dựng bằng bất kỳ tool nào (cắt thô cũng được — nội dung kỹ thuật quan trọng hơn hiệu ứng).
- Mô tả video: link repo, `docs/ROADMAP.md`, bài blog (`docs/blog-post-draft.md` khi đã đăng).
- Thêm link video vào `README.md` (mục Project status hoặc mục "Demo" mới).
- **Không quay** URL/ảnh chứa webhook Discord, access key, mật khẩu admin Keycloak thật (chỉ `admin1/admin1pass`
  của kind là công khai).

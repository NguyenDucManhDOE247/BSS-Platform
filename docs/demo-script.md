# Demo video script — 5 phút (viết GĐ8, cập nhật cho `v2.2.0` ngày 2026-10-02)

**Kịch bản:** sản phẩm thật (2 website) → deploy trên AWS → tải → phá → hồi phục. Quay màn hình (OBS Studio /
Windows Game Bar), giọng nói tiếng Việt (giữ thuật ngữ kỹ thuật tiếng Anh, giống văn phong `learning/`). Ghi hình
**sau khi** đã tự tay chạy qua toàn bộ kịch bản ít nhất 1 lần — video kể lại một câu chuyện đã kiểm chứng thật,
không phải lần thử đầu tiên trên camera.

> ✅ **Từ `v2.2.0` (HTTPS — ADR-012) cảnh trình duyệt quay được trên AWS thật.** Trước đó AWS chỉ có HTTP qua DNS
> của ALB nên PKCE (cần *secure context*) không chạy và cảnh sản phẩm phải quay trên kind. Nay 2 website đăng nhập
> được ở `https://dev.bssplatform.dpdns.org` (staging `staging.…`, prod tên miền gốc) — đã kiểm 2026-10-02 bằng
> `e2e-flow.sh` + Playwright 3/3 + thao tác tay trên cả 3 môi trường. kind vẫn là phương án dự phòng $0.

**Chuẩn bị (2 buổi quay riêng là được, ghép lúc dựng):**
- **dev EKS** (💰 ~$0.3–0.4/giờ — destroy ngay sau khi quay): `make ENV=dev tf-apply` → platform-install →
  db-bootstrap → **CD — dev** xanh → `./scripts/e2e-flow.sh dev` PASS → `./scripts/admin-user.sh dev <tên> <email>`
  (tài khoản nhân viên của bạn; mật khẩu tạm in 1 lần, đổi ở lần đăng nhập đầu — **không quay** màn hình này).
  Mở sẵn 2 cửa sổ trình duyệt: thường cho khách, **ẩn danh** cho nhân viên; và terminal `kubectl -n bss get pods -w`,
  `kubectl -n bss get hpa -w`.
- **kind** ($0, dự phòng nếu không muốn bật AWS): `docs/SETUP.md` / `learning/19` phần 2 → `e2e-flow.sh kind` PASS;
  nhân viên là `admin1`/`admin1pass` (chỉ tồn tại ở local).

## Cảnh 1 — Giới thiệu (0:00 – 0:30)

- Kiến trúc tổng thể (`docs/architecture/bss_eks_architecture.png`): BSS chuẩn TM Forum — 4 microservice
  Spring Boot + gateway + 2 website React + Keycloak, trên EKS dựng bằng Terraform, CI/CD bằng GitHub Actions OIDC.
- 1 câu bối cảnh: nhận scaffold từ thầy, kiểm chứng lại từ đầu, đưa lên chạy thật qua 10 giai đoạn.

## Cảnh 2 — Sản phẩm: 2 website đồng bộ qua cùng backend (dev EKS qua HTTPS, 0:30 – 1:50)

1. **Khách** (`https://dev.bssplatform.dpdns.org` — chỉ ổ khóa TLS trên thanh địa chỉ 1 giây): bấm **Đăng ký** → trang Keycloak → quay về đã đăng nhập → **Hồ sơ**: điền
   tên + SĐT → trạng thái *chờ duyệt*.
2. Vào **Gói cước** → chọn gói → trang giải thích *chưa được duyệt*, **không có nút mua** (backend cũng chặn: 422).
3. **Nhân viên** (cửa sổ ẩn danh, `https://dev.bssplatform.dpdns.org/admin/`): **Khách hàng** → lọc *chờ duyệt* → **Duyệt**.
4. Quay lại khách, tải lại trang gói → **Xác nhận đăng ký** → *Đơn hàng của tôi* có 1 đơn → *Hóa đơn* hiện sau vài
   giây (trang tự làm mới 5s) với VAT 10%. Câu thoại: "đơn và hóa đơn là 2 service khác nhau, nối bằng sự kiện qua
   EventBridge → SQS — nên hóa đơn đến *sau* vài giây, đó là eventual consistency, không phải lỗi."
5. **Admin**: **Dashboard** có số + doanh thu → trang khách → **Đơn** / **Hóa đơn** của đúng khách vừa mua.
6. (Tùy chọn, 10 giây) Admin sửa giá 1 gói → web khách đổi giá ngay; đơn cũ giữ giá lúc mua.

Câu chốt: "Khách khác gọi hóa đơn này nhận **404**, không phải 403 — để không lộ việc hóa đơn đó tồn tại."

## Cảnh 3 — Deploy trên AWS (dev EKS, 1:50 – 2:30)

- Actions → **CD — dev**: quay run xanh (plan → build image thiếu → apply 8 image → rollout → drift → smoke).
- `kubectl -n bss get pods` — đủ Pod `Running` (gồm Keycloak).
- `./scripts/smoke.sh dev` — PASS 7/7 qua **HTTPS với cert thật**, có token Keycloak thật (lấy qua port-forward vì
  `/auth/admin` cố ý không có route ra ALB — chỉ `/auth/realms` + `/auth/resources` ra internet).
- 1 câu: "Không có AWS access key nào trong GitHub — CI nhận quyền tạm qua OIDC, mỗi môi trường một role."

## Cảnh 4 — Tải: trần thật nằm ở đâu (2:30 – 3:10)

- Cắt sang `k6 run tests/load/dev-threshold.js` đã chạy sẵn (tua nhanh) + `get hpa -w`.
- Số thật (dev EKS, `docs/labs/07-load-test-dev.md` + ADR-010): 2 node cố định ổn tới ≥150 req/s (p95 432 ms,
  0% lỗi); 200→700 req/s thì vỡ (p95 8.55 s) vì **hết chỗ đặt Pod** (`kubectl describe pod` → `Insufficient cpu`).
  Bật Karpenter: phục vụ **gấp 2,4 lần** request, p95 3.66 s — nhưng lỗi 7,9%. Câu chuyện đáng kể: con số đó là
  **2 lỗi chồng nhau** — 502 do probe timeout mặc định 1 s (kubelet giết gateway đang bận) và 500 do hết kết nối RDS.
  Probe 5 s/3 s + HikariCP 5 → **0% lỗi, 3 lần đo liền** (lab 07 §2c, #203).

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
- **Không quay** URL/ảnh chứa webhook Discord, access key, mật khẩu admin Keycloak thật, mật khẩu tạm do
  `admin-user.sh` in ra (chỉ `admin1/admin1pass` của kind là công khai).

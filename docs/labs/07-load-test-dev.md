# Lab 07 — Tìm ngưỡng req/s trước khi p95 > 500ms (dev EKS thật)

**Mục tiêu (Giai đoạn 8, việc 1):** trả lời bằng SỐ THẬT câu hỏi capacity-planning (slide 10c đồ
án của bạn) — "hệ thống này chịu được bao nhiêu request/giây trước khi chậm đi rõ rệt?" — đo trên
hạ tầng thật (EKS dev + ALB + RDS), không phải trên `kind` 1 node như Lab k6 ở Giai đoạn 2.

**Học được gì:**
- Vì sao `ramping-arrival-rate` (open model) là lựa chọn đúng để đo ngưỡng, khác `ramping-vus`
  (closed model) dùng để "xem HPA có phản ứng không" ở `tests/load/plans-and-order.js`.
- HPA scale theo CPU có **độ trễ** (metrics-server poll 15s + `stabilizationWindowSeconds`) — số
  rps "vỡ ngưỡng" đo được phụ thuộc `maxReplicas` hiện tại của overlay dev, không phải hằng số vật
  lý của code.
- Cách đọc bảng tổng kết k6 theo **từng bậc** (không chỉ số p95 tổng toàn bài).

⚠️ **Tốn tiền** — cần dev EKS đang chạy thật (không làm được trên `kind`, vì mục tiêu là số đo trên
hạ tầng production-like: ALB thật, RDS thật, network thật giữa các AZ). Xem PROJECT.md §9 "hỏi
trước khi tốn tiền" — chạy lab này trong đúng 1 buổi rồi `terraform destroy` ngay sau, như mọi lần
lên AWS thật trước đó.

## 0. Điều kiện

1. Dev EKS đang chạy, 7 Pod `Running` (xem `docs/runbooks/cd-dev.md` nếu cần deploy lại từ đầu).
2. `k6` đã cài (`k6 version`).
3. Lấy DNS của ALB:
   ```bash
   ALB=$(kubectl -n bss get ingress bss-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   echo "$ALB"
   ```
4. Mở 1 terminal quan sát song song trong lúc chạy:
   ```bash
   kubectl -n bss get hpa -w
   ```

## 1. Chạy bậc thăm dò

```bash
mkdir -p tests/load/results
BASE_URL="http://$ALB" k6 run --summary-export=tests/load/results/dev-threshold.json \
  tests/load/dev-threshold.js
```

Mất khoảng 10 phút (5 bậc × 90s + ramp/cooldown). **Đừng tắt terminal `get hpa -w`** — quan sát
`REPLICAS` tăng theo từng bậc rps, giống hệt cách đọc ở `tests/load/README.md` (Giai đoạn 2),
nhưng lần này trên node EC2 thật (t3.large, không phải 1 node kind).

## 2. Đọc kết quả — tìm đúng bậc "vỡ ngưỡng"

`k6` in bảng tổng kết cuối cùng cho **toàn bài** (không tách theo bậc) — số p95 tổng thường bị kéo
lên bởi các bậc cuối. Để tìm CHÍNH XÁC bậc nào vỡ ngưỡng, chạy `k6` với `--out` ghi log theo mốc
thời gian, hoặc đơn giản hơn: chạy lại `dev-threshold.js` NHIỀU LẦN, mỗi lần sửa 1 dòng `stages`
thành đúng 1 bậc cố định (vd. chỉ giữ `{ target: 50, duration: "90s" }`), lấy p95 riêng của bậc đó.
Cách này chậm hơn nhưng cho số chính xác theo từng mức tải — điền vào bảng dưới:

| rps mục tiêu | p95 đo được | Pass (<500ms)? | REPLICAS lúc ổn định (gateway / order / product) |
|---|---|---|---|
| 10 | | | |
| 25 | | | |
| 50 | | | |
| 100 | | | |
| 150 | | | |

**Ngưỡng = rps lớn nhất còn Pass.** Đây là con số thật để trả lời slide 10c — kèm theo điều kiện đo
(overlay dev, `maxReplicas` hiện tại, instance type node group) vì đây KHÔNG phải hằng số của code,
mà là hằng số của **cấu hình hạ tầng lúc đo**.

## 2b. Kết quả chạy thật (dev EKS, 2× t3.medium, 2026-09-27)

**Lần 1 — đúng 5 bậc trong script gốc (10→150 rps, mỗi bậc 90s):**

| rps | p95 | Pass (<500ms)? |
|---|---|---|
| 10–150 (toàn bài) | **431.9ms** | ✅ (0% request lỗi trên 26.360 request) |

Script gốc chọn dải 10-150 rps **quá thấp** — không tìm ra được ngưỡng thật, chỉ chứng minh hệ
thống chịu được TỐI THIỂU 150 rps. Đây là bài học capacity-planning kinh điển: đoán sai dải cần đo
ở lần thử đầu là chuyện bình thường — phải đo rồi mới biết đẩy tiếp lên đâu, không đoán suông.

**Lần 2 — đẩy tiếp 150→700 rps (script tạm, không commit, xem nhật ký) để tìm điểm vỡ thật:**

| rps | p95 | http_req_failed | Ghi chú |
|---|---|---|---|
| 200–700 (toàn bài, 5 bậc tăng dần) | **8.55s** | **5.47%** (3.226/58.926) | `dropped_iterations`: 57.948 — k6 không tài nào giữ đúng rps mục tiêu, dấu hiệu bão hòa rõ ràng |

**Nguyên nhân gốc — KHÔNG phải CPU mỗi request chậm đi, mà là hết chỗ trên node:**
```
kubectl describe pod api-gateway-...  →
  Warning  FailedScheduling  0/2 nodes are available: 1 Insufficient cpu, 2 Insufficient memory.
```
`api-gateway` chạm trần `maxReplicas: 12` (HPA báo `cpu: 107%/60%` — vượt xa target vì không đủ
pod để chia tải), nhưng **2 node t3.medium chỉ có 1930m CPU / ~3.2GiB allocatable MỖI node** — khi
`api-gateway` + `product-catalog` cùng cần scale lên tổng cộng ~17 pod, node hết chỗ, pod mới kẹt
`Pending` **vĩnh viễn** (managed node group không tự thêm node — đúng ADR-007: đây chính xác là
tình huống mà Karpenter được sinh ra để giải quyết, nhưng dự án đã quyết định không dùng Karpenter
ở giai đoạn này). Số Pod `Ready` không tăng thêm được nữa → toàn bộ tải dư dồn lên số Pod đang có →
hàng đợi tại TCP/ứng dụng phình to → latency tăng phi tuyến (có request tới 34.85s trước khi client
timeout), không phải tăng tuyến tính như CPU throttling thông thường.

**Kết luận (số thật để trả lời slide 10c):** trên cấu hình dev hiện tại (2× t3.medium, HPA
`maxReplicas` như đã cấu hình trong `infrastructure/kubernetes/base/*/hpa.yaml`), hệ thống phục vụ
**ổn định tới ít nhất 150 req/s** (p95 431.9ms, 0% lỗi) và **sụp đổ rõ rệt khi vượt ngưỡng đó lên
vùng 200+ req/s** — nhưng nguyên nhân sụp đổ là **giới hạn số node**, không phải giới hạn CPU per-
pod. Nói cách khác: câu trả lời đúng cho "hệ thống chịu được bao nhiêu rps" không phải một con số
cố định của code, mà là **hàm số của số node đang chạy** — thêm node (hoặc Karpenter tự thêm) sẽ
đẩy ngưỡng này lên, không cần đổi 1 dòng code nào.

## 2c. Lỗi dưới tải: giải thích "7,9%" và sửa (dev EKS + Karpenter, 2026-10-01)

ADR-010 đo 200→700 req/s có Karpenter: lượng request ×2.4 nhưng **7,9% lỗi**, chưa giải thích được (chỉ có
manh mối: alert `BssPodCrashLooping` của api-gateway). Lần này đo lại với 2 công cụ mới:

```bash
STAGES=200,325,450,575,700   # bậc của GĐ8/ADR-010 — trước đây là "script tạm không commit"
./scripts/load-watch.sh '' 14 > results/load-watch.log &      # mỗi 15s: node, Pending, HPA, Pod restart + LÝ DO
k6 run -e BASE_URL=http://<alb> -e STAGES=$STAGES tests/load/dev-threshold.js   # có đếm theo MÃ HTTP
```

**Lần 1 (code `main`, 2026-10-01): 79.364 request, 4,21% lỗi, p95 7,79s** — phân theo mã: **502 = 1.902**,
**500 = 1.447**, 503/504/timeout = 0. Hai nguyên nhân, mỗi cái có bằng chứng trực tiếp:

| | Bằng chứng | Gây ra |
|---|---|---|
| **A. Probe timeout mặc định 1s** | Event `Liveness probe failed … context deadline exceeded` ở 6 Pod api-gateway; container chết `exit 143` (SIGTERM của kubelet) | CPU bão hòa → health check trả > 1s → kubelet **giết Pod đang phục vụ** → ALB trả **502** cho request đang bay; readiness timeout rút Pod khỏi ALB → Pod còn lại gánh thêm |
| **B. Hết kết nối RDS** | CloudWatch `DatabaseConnections` đứng ở **70–72** (trần `db.t3.micro`); 105 dòng `remaining connection slots are reserved`; Pool `total=10/10, idle=10, active=0` | HPA đẩy product-catalog lên 8 Pod × HikariCP **mặc định 10 kết nối giữ sẵn** = 80 → Pod mới chết lúc khởi động (`exit 1`), Pod cũ trả **500** (`Cannot acquire connection`) |

**Sửa** (PR "fix(load)…"): liveness `timeoutSeconds: 5, failureThreshold: 6`, readiness `timeoutSeconds: 3` cho 5
service JVM; HikariCP `maximum-pool-size: 5, minimum-idle: 1` (quy tắc: Σ maxReplicas × pool ≤ max_connections −
dự trữ). Lần 2–4 thử thêm tắt Open Session In View.

| Lần | Cấu hình | Request | Lỗi | p95 | Pod restart |
|---|---|---|---|---|---|
| 1 | `main` | 79.364 | **4,21%** (502 + 500) | 7,79s | 6+ |
| 2 | + probe + pool 5 | 64.994 | **0%** | 9,08s | **0** |
| 3 | + OSIV tắt | 169.923 | **0%** | 3,09s | **0** |
| 4 | **lặp lại đúng lần 3** | 72.455 | **0%** | 6,61s | **0** |

**Kết luận được và không được:**
- ✅ **Lỗi**: 4,21% → **0% ở cả 3 lần sau khi sửa**, 0 restart. Hai nguyên nhân đã đóng.
- ❌ **Thông lượng / p95 KHÔNG kết luận được**: cùng cấu hình (lần 3 và 4) ra 170k và 72k request. Dao động
  giữa các lần (máy đo ở nhà, qua Internet tới Singapore; `maxVUs: 300` nên khi chậm k6 tự hụt nhịp —
  `dropped_iterations` 26k–131k; cụm luôn kẹt ở trần 8 vCPU Spot với 4–9 Pod Pending) lớn hơn mọi khác biệt
  do cấu hình. OSIV giữ tắt vì đúng khuyến nghị + 59 test xanh, **không** vì đã chứng minh tăng tốc. Muốn đo
  thông lượng nghiêm túc: đặt máy k6 **trong cùng region** (EC2/Pod), tăng `maxVUs`, lặp ≥ 3 lần mỗi cấu hình.
- Pod "nóng" (Pod đầu tiên, gánh hết tải trước khi HPA kịp thêm Pod) vẫn chờ kết nối trung bình ~1s ở pool 5 —
  dấu hiệu CPU của Pod đó bão hòa trong ~1 phút đầu (HPA + JVM khởi động chậm hơn đỉnh tải), không phải lỗi.

**Lỗi thật lộ thêm khi đưa cụm về trạng thái nghỉ giữa các lần đo:**
- **HPA memory của customer-service kẹt chiều tăng**: lúc NGHỈ (CPU 3%), JVM giữ ~370Mi = 72% request → mỗi lần
  khởi động vượt 80% → 1→6 Pod trong 4 phút, rồi không bao giờ giảm (cần < ~67%). Sửa: chỉ scale theo CPU.
- **PDB `minAvailable: 1` + 1 replica ở dev chặn Karpenter gom node**: node Spot nằm lại vô thời hạn sau tải
  (ALLOWED DISRUPTIONS = 0). Sửa: overlay dev `maxUnavailable: 1` — node được gom **trong < 1 phút** sau đó.
- `scripts/smoke.sh` chạy tay từ Windows luôn báo "Keycloak chưa sẵn sàng": cổng port-forward 18080 nằm trong
  dải Hyper-V giữ (18028–18127). Sửa: `SMOKE_KC_PORT`.

## 3. (Tùy chọn) Tìm nút thắt cổ chai

Nếu `order-management` chạm `maxReplicas` trước khi p95 vỡ ngưỡng ở `api-gateway`, đó là nút thắt.
Kiểm bằng:
```bash
kubectl -n bss top pods    # cần metrics-server (đã có, B-43)
```
So sánh CPU/memory usage giữa các service ngay lúc rps cao nhất — service nào chạm `limits` trước
là ứng viên đầu tiên để tăng `resources.limits` hoặc `maxReplicas` trong
`infrastructure/kubernetes/base/<service>/hpa.yaml`.

## 4. Dọn dẹp

```bash
rm -rf tests/load/results   # kết quả cá nhân, không commit số đo cụ thể của 1 lần chạy vào git
```
Điền số liệu **tóm tắt** (ngưỡng cuối cùng + điều kiện đo) vào `learning/nhat-ky-hoc-tap.md`, rồi
`terraform destroy` dev như thường lệ.

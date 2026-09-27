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
hạ tầng production-like: ALB thật, RDS thật, network thật giữa các AZ). Xem CLAUDE.md §9 "hỏi
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

# Lab 08 — Chaos engineering: xóa pod ngẫu nhiên, drain node

**Mục tiêu (Giai đoạn 8, việc 2):** chứng minh bằng thực nghiệm — không phải bằng cách đọc YAML —
rằng hệ thống chịu được 2 loại lỗi hạ tầng phổ biến nhất: 1 Pod chết đột ngột, và 1 node bị rút
khỏi cluster (bảo trì, hoặc AWS thu hồi Spot Instance).

**Học được gì:**
- ReplicaSet tự tạo lại Pod khi Pod bị xóa — nhưng "tự tạo lại" không đồng nghĩa "không mất
  request" nếu chỉ có 1 replica. Đây là lý do `minReplicas ≥ 2` ở staging/prod (không phải ở dev).
- `PodDisruptionBudget.minAvailable` là ranh giới **cứng**: `kubectl drain` sẽ TỰ CHẶN nếu di dời
  một Pod sẽ vi phạm nó — đúng thiết kế, không phải bug khi lab này "thất bại" trên cluster nhỏ.
- Resilience4j (circuit breaker + retry, B-13) bảo vệ **caller** (order-management) khi
  **callee** (product-catalog) tạm thời không sẵn sàng trong lúc Pod của nó đang được thay thế.

⚠️ Chạy được trên `kind` (miễn phí) cho phần "xóa Pod"; phần "drain node" học được nhiều hơn trên
cluster ≥ 2 node thật (dev EKS) vì `kind` mặc định 1 node sẽ luôn chặn drain (không có node nào
khác để nhận Pod) — đó vẫn là một kết quả đúng và đáng học (xem bước 3), nhưng để thấy Pod THẬT SỰ
di dời sang node khác, cần EKS dev (2 node, xem `learning/20-lo-trinh-hoan-thanh.md` Giai đoạn 4).

## 0. Điều kiện

- `kind` cluster đang chạy (`scripts/kind-up.sh`) HOẶC dev EKS đang chạy, overlay `bss` đã deploy.
- 1 terminal chạy sẵn:
  ```bash
  kubectl -n bss port-forward svc/api-gateway 8080:8080
  ```
  (không cần nếu bạn đang chạy trên `kind` với ingress — đặt `SMOKE_BASE_URL=http://bss.localtest.me`).

## 1. Thí nghiệm A — xóa 1 Pod của `order-management`

```bash
SMOKE_BASE_URL=http://localhost:8080 ./scripts/chaos-delete-pod.sh bss order-management
```

Script tự: chọn 1 Pod ngẫu nhiên trong số các Pod `app=order-management` → xóa đúng Pod đó → bắn
30 giây request song song vào `/api/tmf-api/productCatalog/v4/productOffering` (endpoint không phụ
thuộc `order-management`, dùng để chứng minh **service khác không bị ảnh hưởng**) → đo thời gian
tới khi đủ số Pod `Ready` trở lại.

**Kỳ vọng:**
- Nếu overlay có `replicas: 1` (dev, B-22) — sẽ có request lỗi thật trong lúc Pod khởi động lại.
  Đây KHÔNG phải lab thất bại — đây chính là bằng chứng sống cho "dev không HA, đúng như thiết kế
  cost-saving của CLAUDE.md §4 sizing table".
- Nếu overlay có `replicas ≥ 2` (staging/prod) — 0 request lỗi. Chạy lại lab với
  `kubectl -n bss scale deploy/order-management --replicas=2` trên dev để tự thấy sự khác biệt.

Ghi lại: thời gian hồi phục (giây) + số request lỗi / tổng số request, vào nhật ký.

## 2. Thí nghiệm B — làm `product-catalog` "chết" để xem Resilience4j phản ứng

Trong lúc thí nghiệm A đang xóa Pod `order-management`, thử đặt luôn 1 đơn hàng thật (gọi
`order-management`, mà `order-management` lại gọi `product-catalog` để lấy giá — B-13):

```bash
curl -X POST "http://localhost:8080/api/tmf-api/productOrderingManagement/v4/productOrder" \
  -H 'Content-Type: application/json' -d '{...}'   # xem docs/api/ hoặc packages/api-contracts để có body mẫu
```

Nếu gọi đúng lúc Pod `product-catalog` (không phải `order-management`) đang bị chaos xóa: quan sát
log `order-management` — Resilience4j sẽ `retry` (tối đa 3 lần, cách nhau 200ms —
`application.yml` mục `resilience4j.retry.instances.productCatalog`) trước khi tính là lỗi thật.
Với 1 Pod bị xóa trong cluster có ≥ 2 Pod `product-catalog`, retry gần như luôn thành công (request
thứ 2 rơi vào Pod còn sống) — **đây là lý do B-13 chọn retry, không chỉ circuit breaker.**

## 3. Thí nghiệm C — drain 1 node

```bash
./scripts/chaos-drain-node.sh
```

- Trên `kind` 1 node: script sẽ **báo lỗi có chủ đích** — `kubectl drain` không tìm được chỗ nhận
  Pod hệ thống (CoreDNS, ingress-nginx) nên treo/timeout. Đọc kỹ log — đây là bài học "single point
  of failure ở tầng node", không phải script hỏng.
- Trên dev EKS (2 node): Pod sẽ di dời hết sang node còn lại; nếu di dời sẽ vi phạm
  `PodDisruptionBudget` của service nào đó (`kubectl -n bss get pdb` — mọi service base đều có
  `maxUnavailable: 0` theo CLAUDE.md §7, xem `infrastructure/kubernetes/base/<svc>/pdb.yaml`),
  `drain` sẽ đứng chờ đúng ở Pod đó cho tới khi ReplicaSet tạo được bản thay thế trên node kia
  trước — quan sát bằng `kubectl -n bss get pods -o wide -w` ở 1 terminal khác trong lúc drain chạy.

Script tự `uncordon` lại node ở cuối (kể cả khi drain fail) — kiểm lại bằng `kubectl get nodes`
(cột `STATUS` không còn `SchedulingDisabled`).

## 4. Ghi vào nhật ký

Với mỗi thí nghiệm: **con số thật** (thời gian hồi phục, số request lỗi, drain PASS/FAIL trên
cluster nào) — không ghi "đã chạy thành công" chung chung. Đây là dữ liệu dùng lại cho
`docs/POSTMORTEMS.md` và cho video demo Giai đoạn 8 việc 6 ("deploy → phá → hồi phục").

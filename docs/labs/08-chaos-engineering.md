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
  (không cần nếu bạn đang chạy trên `kind` với ingress — đặt `SMOKE_BASE_URL=http://bss.localhost`).

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

⚠️ **2 điều tự bắt được khi chạy thật lần đầu (2026-09-27, kind) — đọc trước khi chạy:**
1. **`PROBE_PATH` mặc định trỏ tới `product-catalog`**, không phải `order-management` — đúng ý đồ
   ban đầu (chứng minh SERVICE KHÁC không bị ảnh hưởng), nhưng nếu bạn muốn thấy `order-management`
   **tự nó** có bị gián đoạn không, phải trỏ `PROBE_PATH` sang chính endpoint của nó, có
   `customerId` hợp lệ (lấy từ `GET /api/tmf-api/customerManagement/v4/customer`):
   ```bash
   PROBE_PATH="/api/tmf-api/orderManagement/v4/productOrder?customerId=<uuid-thật>" \
     SMOKE_BASE_URL=http://bss.localhost ./scripts/chaos-delete-pod.sh bss order-management
   ```
2. **`kubectl scale --replicas=2` có thể bị HPA âm thầm trả về 1** ngay sau đó, nếu overlay đặt
   `minReplicas: 1` (đúng trường hợp dev/local, B-22) — HPA reconcile lại theo metric, ghi đè lệnh
   scale tay của bạn trong vài giây. Muốn scale tay "dính" thật, phải nâng luôn `minReplicas` của
   HPA trước:
   ```bash
   kubectl -n bss patch hpa order-management --type=merge -p '{"spec":{"minReplicas":2}}'
   kubectl -n bss scale deploy/order-management --replicas=2
   # ... chạy lab xong, nhớ trả lại:
   kubectl -n bss patch hpa order-management --type=merge -p '{"spec":{"minReplicas":1}}'
   ```

**Kết quả 1 lần chạy thật (kind, `bss-control-plane`, 2026-09-27):**

| Cấu hình | Recovery time | Request lỗi / tổng |
|---|---|---|
| `replicas: 1` (mặc định dev/local) | 21s | **9 / 26** |
| `replicas: 2` (HPA `minReplicas` nâng tạm) | 22s | **0 / 56** |

Đúng khớp lý thuyết: cùng một thời gian hồi phục (~20s, do JVM Spring Boot khởi động, không đổi
theo số replica), nhưng số request lỗi phụ thuộc HOÀN TOÀN vào việc còn pod nào khác phục vụ trong
lúc đó hay không. **Bug thật tự bắt được khi viết lab này:** bản đầu của `chaos-delete-pod.sh` đo
"0s hồi phục" (sai) vì đếm luôn container của pod VỪA bị xóa (đang ở `Terminating` nhưng
`containerStatuses[0].ready` có thể vẫn `true` trong lúc chờ hết grace period) — đã sửa bằng cách
loại trừ đúng tên pod nạn nhân khỏi phép đếm (xem diff script + nhật ký).

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

**Kết quả 1 lần chạy thật (kind 1 node, `bss-control-plane`, 2026-09-27):** đúng như dự đoán ở
trên — `drain` cordon được node, evict thành công các pod KHÔNG có PDB chặn (Postgres, Keycloak,
LocalStack, CoreDNS, ingress-nginx, toàn bộ addon `monitoring/`) nhưng **treo vĩnh viễn** (retry
mỗi 5s, timeout sau 180s) ở các pod có PDB `minAvailable: 1` + chỉ 1 replica (`api-gateway`,
`admin-console`, `billing-service`, `product-catalog`, `web-portal`, và `customer-service`/
`order-management` khi chỉ có 1 pod) — log lặp lại đúng dòng
`Cannot evict pod as it would violate the pod's disruption budget`. Script thoát exit 1 (đúng thiết
kế), **nhưng trap vẫn `uncordon` được node** — xác nhận `kubectl get nodes` sau đó vẫn `Ready`,
không `SchedulingDisabled`. Các pod không-PDB bị evict xong tự mọc lại **trên chính node đó** (vì
là node duy nhất) — không mất dữ liệu do đều dùng `emptyDir`/dữ liệu seed lại từ Flyway lúc khởi
động; `keycloak` mất ~30-40s để sẵn sàng lại do Quarkus rebuild config lúc boot (bình thường, không
phải bug).

**Kết quả chạy thật lần 2 — dev EKS THẬT, 2 node, sau khi Lab 07 vừa chạy xong (2026-09-27) —
⚠️ SỬA LẠI dự đoán ban đầu, đây là phát hiện quan trọng nhất của cả buổi:** dự đoán ở trên ("có ≥2
node thì Pod sẽ di dời sang node còn lại nếu không vi phạm PDB") **chỉ đúng một nửa**. Chạy thật
`./scripts/chaos-drain-node.sh` nhắm đúng node đang có 6/7 pod ứng dụng: **drain vẫn treo và fail
sau 3 phút**, `kubectl get pdb` cho thấy lý do — `admin-console`, `billing-service`,
`customer-service`, `order-management`, `product-catalog`, `web-portal` đều có `ALLOWED
DISRUPTIONS: 0` vì **đúng 1 replica + `minAvailable: 1`**. Đây KHÔNG phải vấn đề "hết chỗ trên
node" (2 node dev EKS có `~1930m CPU`/`~3.2GiB` mỗi node, dư sức nhận thêm 1 pod nhỏ) — mà là toán
học của chính PodDisruptionBudget: **evict đòi hỏi số pod khả dụng KHÔNG ĐƯỢC GIẢM tại đúng thời
điểm evict**, nhưng với đúng 1 pod + `minAvailable:1`, evict bất kỳ lúc nào cũng lập tức đưa số khả
dụng về 0 → luôn bị chặn — **bất kể cluster có bao nhiêu node trống**. Khác với rolling update của
Deployment (tạo pod mới TRƯỚC khi xóa pod cũ, nhờ `maxSurge`), API evict dùng cho `drain` không có
cơ chế "tạo trước" này.

**Ca ngoại lệ tự quan sát được — bằng chứng THẬT cho việc Pod di chuyển sang node khác:**
`api-gateway` lúc đó còn 2 replica (dư lại từ lúc HPA scale-up cho Lab 07, chưa kịp scale về 1) →
PDB báo `ALLOWED DISRUPTIONS: 1` → drain evict THÀNH CÔNG 1 trong 2 pod `api-gateway` trên node bị
drain, và `kubectl get pods -o wide` xác nhận pod thay thế xuất hiện **trên node CÒN LẠI**
(`api-gateway-...-fc89s`, mới 3m31s tuổi, `NODE=ip-10-10-10-118...`, khác hẳn node bị drain
`ip-10-10-11-196...`). **Kết luận đúng:** Pod chỉ thực sự "di chuyển" được qua `drain` khi service
đó có **> 1 replica đang chạy tại thời điểm drain** — với dev sizing mặc định (`minReplicas: 1`
mọi service, B-22), **không service nghiệp vụ nào của dev có thể được drain an toàn**, kể cả trên
cluster nhiều node — đây chính là lý do CLAUDE.md §4 quy định staging/prod phải có `replicas ≥ 2`.

## 4. Ghi vào nhật ký

Với mỗi thí nghiệm: **con số thật** (thời gian hồi phục, số request lỗi, drain PASS/FAIL trên
cluster nào) — không ghi "đã chạy thành công" chung chung. Đây là dữ liệu dùng lại cho
`docs/POSTMORTEMS.md` và cho video demo Giai đoạn 8 việc 6 ("deploy → phá → hồi phục").

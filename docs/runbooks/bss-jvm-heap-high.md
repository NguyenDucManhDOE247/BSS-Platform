# Runbook: JVM heap cao (`BssJvmHeapHigh`)

> Alert: heap đang dùng / heap tối đa > 85% suốt 15 phút. Cảnh báo *sớm* — trước khi có `OutOfMemoryError`
> hoặc `OOMKilled` (vòng `bss-pod-crash-looping.md`).

## 1. Phân biệt "đầy nhưng khỏe" với "rò rỉ"

Heap của JVM tự nhiên dâng lên rồi tụt xuống theo chu kỳ GC (răng cưa). Điều đáng lo là **đáy của răng cưa
tăng dần** (sau mỗi lần GC vẫn không thu hồi được → giữ tham chiếu → rò rỉ).

```promql
# Heap dùng theo thời gian (xem đồ thị 6 giờ, tìm "đáy" tăng dần)
sum by (pod) (jvm_memory_used_bytes{area="heap",namespace="bss",application="<service>"})
# Tần suất/thời gian GC — GC dày đặc mà heap không giảm = dấu hiệu xấu
rate(jvm_gc_pause_seconds_sum{namespace="bss",application="<service>"}[5m])
```

- Đáy ổn định, chỉ đỉnh cao (traffic dồn) → tăng `limits.memory` hợp lý hoặc scale ngang.
- Đáy tăng dần theo giờ/ngày → **rò rỉ bộ nhớ** → mục 3.

## 2. Kiểm tra cấu hình bộ nhớ (lỗi hay gặp nhất)

JVM trong container tính heap tối đa = `MaxRAMPercentage` × `limits.memory` (Dockerfile đặt 75%). Phần còn
lại (25%) dành cho **non-heap**: metaspace, thread stack, direct buffer (Netty!), code cache. Nếu
`limits.memory` sát `MaxRAMPercentage` → tổng vượt limit → **OOMKilled dù heap chưa đầy**.

```bash
kubectl -n bss get deploy <service> -o jsonpath='{.spec.template.spec.containers[0].resources}'
kubectl -n bss top pod -l app=<service>     # cần metrics-server
kubectl -n bss describe pod <pod> | grep -A3 "Last State"    # OOMKilled?
```

## 3. Nghi rò rỉ → lấy heap dump

```bash
# Container chạy non-root + rootfs read-only → ghi dump ra /tmp (emptyDir)
kubectl -n bss exec <pod> -- jcmd 1 GC.heap_dump /tmp/heap.hprof
kubectl -n bss cp <pod>:/tmp/heap.hprof ./heap.hprof
# Mở bằng Eclipse MAT / VisualVM: "Leak Suspects", xem class nào giữ nhiều bộ nhớ nhất.
```

Thủ phạm hay gặp ở Spring: cache không giới hạn (`ConcurrentHashMap` tự tăng), `@Scheduled` tích lũy dữ
liệu, phân trang thiếu (`findAll()` toàn bảng), session/connection không đóng.

## 4. Giảm nhẹ tạm thời

- Restart Pod tuần tự (`kubectl -n bss rollout restart deploy/<service>` — `maxUnavailable: 0` giữ dịch vụ).
- Tăng `limits.memory` (kèm `requests`) trong `infrastructure/kubernetes/base/<service>/deployment.yaml`
  qua PR — **không** sửa tay trên cluster (CD sẽ ghi đè).

## 5. Sau sự cố

Nếu là rò rỉ thật: viết test/benchmark tái hiện, sửa gốc, và thêm vào `docs/POSTMORTEMS.md`.

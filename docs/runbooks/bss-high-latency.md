# Runbook: latency cao (`BssHighRequestLatency`)

> Alert: p95 của một `uri` của một `application` > 1 giây suốt 10 phút
> (`platform/monitoring/alerts/bss-alerts.yaml`). Cảnh báo mức *warning* — người dùng đã thấy chậm
> nhưng hệ thống chưa gãy.

## 1. Đọc đúng con số

```promql
histogram_quantile(0.95,
  sum by (le, uri) (rate(http_server_requests_seconds_bucket{namespace="bss",application="<service>"}[5m])))
```

- Chỉ **một** `uri` chậm → vấn đề nằm ở đúng endpoint đó (query DB thiếu index, gọi service khác).
- **Mọi** `uri` cùng chậm → vấn đề chung: CPU throttling, GC, connection pool, node chật, DB chậm.
- Nhớ `histogram_quantile` phải giữ nhãn `le` trong `sum by (...)`.

## 2. Ba câu hỏi phân loại nhanh

| Câu hỏi | Lệnh / PromQL | Nếu "có" |
|---|---|---|
| CPU bị bóp (throttle)? | `rate(container_cpu_cfs_throttled_periods_total{namespace="bss",pod=~"<svc>.*"}[5m]) / rate(container_cpu_cfs_periods_total{namespace="bss",pod=~"<svc>.*"}[5m])` > 0.25 | `limits.cpu` quá thấp → tăng limit hoặc scale ngang (HPA). |
| JVM đang GC nhiều / heap gần đầy? | `jvm_gc_pause_seconds_sum`, `jvm_memory_used_bytes{area="heap"}` | Sang `bss-jvm-heap-high.md`. |
| DB chậm / hết connection? | `hikaricp_connections_active`, `hikaricp_connections_pending` (nếu bật), log `Connection is not available` | Tăng pool hoặc tối ưu query; xem RDS CloudWatch (CPU, connections). |

## 3. Phụ thuộc bên ngoài

`order-management` gọi `product-catalog` (B-13); mọi service gọi RDS; billing/order gọi SQS/EventBridge.
Latency của service A = latency của A + của những thứ A chờ. Xem `application` **phía dưới** trước.
Nếu bật tracing (GĐ7 — OTel), mở trace của một request chậm để thấy span nào tốn thời gian.

## 4. Tạm thời giảm nhẹ

```bash
kubectl -n bss get hpa                       # HPA đã scale chưa? (cần metrics-server)
kubectl -n bss scale deploy/<service> --replicas=<n+1>   # scale tay nếu HPA chưa kịp (sẽ bị HPA/CD ghi đè về sau)
```

Nếu sau một lần deploy mới thì rollback (chạy lại cd-dev từ commit tốt — xem `docs/runbooks/cd-dev.md`).

## 5. Sau sự cố

Ghi lại nguyên nhân + đưa vào `docs/POSTMORTEMS.md` nếu làm người dùng chịu ảnh hưởng thật. Cân nhắc đo
ngưỡng chịu tải bằng k6 (`tests/load/`) để biết hệ thống chậm từ bao nhiêu req/s.

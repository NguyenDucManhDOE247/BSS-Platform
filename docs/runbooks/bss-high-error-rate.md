# Runbook: tỉ lệ lỗi 5xx cao (`BssHighErrorRate`)

> Alert: 5xx / tổng request của một `application` > 5% suốt 5 phút (`platform/monitoring/alerts/bss-alerts.yaml`).
> Mức **critical** — người dùng đang nhận lỗi. Các alert khác có runbook riêng:
> `bss-service-down.md`, `bss-high-latency.md`, `bss-pod-crash-looping.md`, `bss-jvm-heap-high.md`.
> Cài kênh nhận thông báo + kiểm tra đường ống: `alerting-setup.md`.

## 1. Xác nhận alert là thật

Mở Prometheus (`kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090`,
vào `localhost:9090`) và chạy đúng PromQL của alert:

```promql
sum by (application) (rate(http_server_requests_seconds_count{namespace="bss",status=~"5.."}[5m]))
/
sum by (application) (rate(http_server_requests_seconds_count{namespace="bss"}[5m]))
```

- Ra số khớp ngưỡng → alert đúng, sang mục 2.
- Không ra series nào → ServiceMonitor chưa scrape được (`alerting-setup.md` mục 4).
- Tỉ lệ cao nhưng **lưu lượng cực thấp** (vd. 1 lỗi/20 request lúc nửa đêm) → có thể là nhiễu; xem SLO
  (`docs/SLO.md`) để biết có đang đốt error budget thật không.

## 2. Lỗi nằm ở đâu — theo `uri` và `status`

```promql
sum by (uri, status) (rate(http_server_requests_seconds_count{namespace="bss",application="<service>",status=~"5.."}[5m]))
```

| Status | Thường nghĩa là |
|---|---|
| 500 | Exception chưa xử lý trong app → đọc log |
| 502/503/504 (qua gateway) | Service phía sau chết/quá tải/timeout → `bss-service-down.md` |
| 500 từ endpoint phụ thuộc DB/AWS | Phụ thuộc ngoài hỏng: Postgres/RDS, SQS/EventBridge |

## 3. Đọc log

```bash
kubectl -n bss logs deploy/<service> --tail=200 | grep -i -E "ERROR|Exception"
# Từ GĐ7 log là JSON (có trường trace_id): lọc theo một request cụ thể
kubectl -n bss logs deploy/<service> --tail=500 | jq -c 'select(.level=="ERROR")'
```

Trên AWS: CloudWatch Logs Insights → `fields @timestamp, level, message, trace_id | filter level = "ERROR" | sort @timestamp desc`.

Có `trace_id` → tìm cùng `trace_id` ở service khác (gateway → order → …) để ráp lại đường đi của một request lỗi.

## 4. Ép lỗi 500 để tự kiểm tra toàn chuỗi (metric → alert → Alertmanager → kênh chat)

Không có endpoint "cố tình lỗi" — tạo tải lỗi thật bằng order tham chiếu offering không tồn tại, trong
vòng 5 phút (ngưỡng `for` của alert):

```bash
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST http://bss.localtest.me/api/tmf-api/orderManagement/v4/productOrder \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
    -d '{"customerId":"00000000-0000-0000-0000-000000000000","category":"new","items":[{"productOfferingId":"00000000-0000-0000-0000-000000000000","quantity":1}]}'
  sleep 2
done
```

(`$TOKEN`: từ GĐ7 gateway yêu cầu JWT — xem `docs/runbooks/auth.md` mục "Lấy token".) Theo dõi Alertmanager
(`:9093`): `BssHighErrorRate` chuyển `Firing` trong ≤ 10 phút (`for: 5m` + scrape 30 giây + `group_wait`).

## 5. Giảm nhẹ

- Lỗi bắt đầu ngay sau deploy → rollback (chạy lại cd-dev từ commit tốt, `docs/runbooks/cd-dev.md`).
- Do phụ thuộc chết → khắc phục phụ thuộc; cân nhắc circuit breaker (Resilience4j — Giai đoạn 8).
- Do quá tải → scale ngang (`kubectl -n bss scale deploy/<service> --replicas=<n>`), xem `bss-high-latency.md`.

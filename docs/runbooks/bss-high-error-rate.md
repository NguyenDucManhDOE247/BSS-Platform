# Runbook: BSS — tỉ lệ lỗi 5xx cao / service down / latency cao / pod crash loop / JVM heap cao

> Runbook dùng chung cho cả 5 alert trong `platform/monitoring/alerts/bss-alerts.yaml`
> (`BssServiceDown`, `BssHighRequestLatency`, `BssHighErrorRate`, `BssPodCrashLooping`,
> `BssJvmHeapHigh`) — mỗi alert trỏ `runbook_url` về đúng file này. Runbook đầu tiên của dự án
> (CLAUDE.md §10: "Mọi alert có `runbook_url` annotation").

## 1. Xác nhận alert là thật (không phải false positive)

Mở Prometheus UI (`kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090`
rồi vào `localhost:9090`), chạy đúng PromQL của alert đang Firing (copy từ
`platform/monitoring/alerts/bss-alerts.yaml`, ví dụ với `BssHighErrorRate`):

```promql
sum by (application) (rate(http_server_requests_seconds_count{namespace="bss",status=~"5.."}[5m]))
/
sum by (application) (rate(http_server_requests_seconds_count{namespace="bss"}[5m]))
```

Nếu số ra khớp ngưỡng trong `expr` của alert (> 0.05 cho lỗi, > 1.0s cho latency...) → alert
đúng, sang bước 2. Nếu Prometheus không trả về series nào → khả năng cao ServiceMonitor chưa
scrape được (xem mục 4).

## 2. Xử lý ngay theo từng alert

| Alert | Lệnh chẩn đoán đầu tiên | Xử lý ngay |
|---|---|---|
| `BssServiceDown` | `kubectl -n bss get pods -l app=<service>` | Pod `CrashLoopBackOff`/`Pending` → xem `learning/13` mục 7 bảng triệu chứng. Pod `Running` nhưng vẫn Down → `kubectl -n bss get endpoints <service>` rỗng thường là readiness fail. |
| `BssHighErrorRate` | `kubectl -n bss logs deploy/<service> --tail=100 \| grep ERROR` | Tìm exception lặp lại; nếu liên quan DB/AWS phụ thuộc ngoài (Postgres/LocalStack) — kiểm tra Pod đó trước. |
| `BssHighRequestLatency` | Prometheus: `histogram_quantile(0.95, sum by (le,uri)(rate(http_server_requests_seconds_bucket{application="<svc>"}[5m])))` theo từng `uri` | Endpoint cụ thể nào chậm? Có phải đang gọi service khác đang chậm (order-management → product-catalog, xem B-13)? |
| `BssPodCrashLooping` | `kubectl -n bss describe pod <pod>` (đọc `Last State` + `Exit Code`), `kubectl -n bss logs <pod> --previous` | Exit code 1 thường là lỗi khởi động (xem log); 137 là bị OOMKilled → xem alert JVM heap. |
| `BssJvmHeapHigh` | `kubectl -n bss top pod <pod>` (cần metrics-server) | Heap liên tục cao là dấu hiệu memory leak hoặc `limits.memory` đặt quá sát `-XX:MaxRAMPercentage=75` của JVM — xem `learning/13` mục 2.1 "Tính memory cho JVM". |

## 3. Tạo webhook Discord hoặc Slack (nếu chưa có — xem `docs/adr/ADR-001-alerting-channel.md`)

### Discord

1. Server Settings → **Integrations** → **Webhooks** → **New Webhook**.
2. Chọn kênh nhận (vd. `#bss-alerts`), đặt tên, **Copy Webhook URL**.
3. Trong `platform/monitoring/prometheus/values-local.yaml`, bỏ comment khối `discord_configs`
   dưới `alertmanager.config.receivers`, dán URL vào `webhook_url`.
4. `helm upgrade monitoring prometheus-community/kube-prometheus-stack -n monitoring -f platform/monitoring/prometheus/values-local.yaml --version 91.4.0` (giữ đúng version đã cài).

### Slack

1. Vào [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**.
2. **Incoming Webhooks** → bật **Activate Incoming Webhooks** → **Add New Webhook to Workspace**
   → chọn kênh → **Copy** URL (dạng `https://hooks.slack.com/services/T.../B.../...`).
3. Bỏ comment khối `slack_configs` trong `values-local.yaml`, dán vào `api_url`.
4. `helm upgrade` như trên.

### Kiểm tra webhook hoạt động (không cần đợi alert thật)

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093
# Alertmanager UI → New Silence / hoặc gửi alert test qua amtool:
amtool alert add alertname="Test" --alertmanager.url=http://localhost:9093
```

Thấy tin nhắn xuất hiện trong Discord/Slack trong vài giây → webhook đúng.

## 4. ServiceMonitor không scrape được (Prometheus Targets không thấy service)

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
# Status → Targets → tìm job "bss-services"
```

Không thấy target nào:
- `kubectl -n bss get servicemonitor bss-services -o yaml` — kiểm tra `spec.selector` có khớp
  nhãn `tier` trên Service thật không (`kubectl -n bss get svc --show-labels`).
- `kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}'` —
  nếu không rỗng, có thể chart giới hạn ServiceMonitor theo nhãn cụ thể (values đã set
  `serviceMonitorSelectorNilUsesHelmValues: false` để chọn hết, kiểm tra values đang dùng đúng
  file `values-local.yaml` không).

## 5. Ép lỗi 500 để tự kiểm tra toàn bộ chuỗi (metric → alert → Alertmanager)

Không có endpoint "cố tình lỗi" sẵn trong repo — cách nhanh nhất để tạo tải lỗi thật: gọi order
với `productOfferingId` không tồn tại lặp lại nhiều lần trong vòng 5 phút (ngưỡng `for` của
`BssHighErrorRate`):

```bash
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST http://bss.localtest.me/api/tmf-api/orderManagement/v4/productOrder \
    -H 'Content-Type: application/json' \
    -d '{"customerId":"00000000-0000-0000-0000-000000000000","category":"new","items":[{"productOfferingId":"00000000-0000-0000-0000-000000000000","quantity":1}]}'
  sleep 2
done
```

Theo dõi Alertmanager UI (`:9093`) — `BssHighErrorRate` phải chuyển `Firing` trong ≤ 10 phút
(alert có `for: 5m` + tối đa 30s scrape interval + thời gian Alertmanager `group_wait`/
`group_interval`). Nếu đã cấu hình webhook, tin nhắn phải tới kênh trong khoảng thời gian đó.

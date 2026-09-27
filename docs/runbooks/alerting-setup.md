# Runbook: cài kênh cảnh báo (Discord/Slack), kiểm tra chuỗi metric → alert → tin nhắn

> Không phải runbook của một alert cụ thể — đây là **hướng dẫn dựng đường ống**. Các alert ở
> `platform/monitoring/alerts/bss-alerts.yaml` chỉ có ý nghĩa nếu có người thật nhận được thông báo
> (xem `docs/adr/ADR-001-alerting-channel.md`). Tách ra từ `bss-high-error-rate.md` ở Giai đoạn 7.

## 1. Tạo webhook

### Discord
1. Server Settings → **Integrations** → **Webhooks** → **New Webhook**.
2. Chọn kênh (vd. `#bss-alerts`), **Copy Webhook URL**.

### Slack
1. [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**.
2. **Incoming Webhooks** → **Activate** → **Add New Webhook to Workspace** → chọn kênh → **Copy** URL.

> ⚠️ URL webhook = **bí mật nhẹ**: ai có nó cũng gửi được tin vào kênh của bạn. Không commit, không dán
> vào chat/ảnh chụp màn hình.

## 2. Nạp webhook vào cluster (không commit)

`scripts/monitoring-install.sh` nhận URL qua **biến môi trường**, tạo Kubernetes Secret
`alertmanager-webhook` rồi cấu hình Alertmanager đọc URL **từ file trong Secret** (`webhook_url_file` /
`api_url_file`) — nên URL không xuất hiện trong values, không nằm trong lịch sử Helm.

```bash
# kind (local) — hoặc thay `kind` bằng dev|staging|prod
ALERT_WEBHOOK_KIND=discord ALERT_WEBHOOK_URL='https://discord.com/api/webhooks/...' \
  ./scripts/monitoring-install.sh kind
```

Không đặt `ALERT_WEBHOOK_URL` → script vẫn cài, nhưng in **cảnh báo to** rằng alert sẽ "câm" (Firing nhưng
không ai nhận) — đúng nợ kỹ thuật có chủ đích của ADR-001, nay được nói ra thay vì lặng lẽ.

## 3. Gửi thử một alert (không cần đợi sự cố thật)

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &
curl -s -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
  "labels":{"alertname":"TestAlert","severity":"warning","namespace":"bss"},
  "annotations":{"summary":"Tin nhắn thử","runbook_url":"https://github.com/NguyenDucManhDOE247/BSS-Platform/blob/main/docs/runbooks/alerting-setup.md"}}]'
```

Tin xuất hiện trong kênh sau ~`group_wait` (30 giây) → đường ống thông.

## 4. ServiceMonitor không scrape được (Prometheus Targets không thấy service)

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
# Status → Targets → tìm job "bss-services"
```

Không thấy target nào:
- `kubectl -n bss get servicemonitor bss-services -o yaml` — `spec.selector` phải khớp nhãn `tier` trên Service thật
  (`kubectl -n bss get svc --show-labels`).
- `kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}'` — nếu không rỗng
  thì chart đang giới hạn ServiceMonitor theo nhãn; values đã đặt `serviceMonitorSelectorNilUsesHelmValues: false`.
- Có NetworkPolicy chặn namespace `monitoring` → `docs/runbooks/network-policy.md`.

## 5. Ép sự cố thật để kiểm tra toàn chuỗi

- **Service chết:** `kubectl -n bss scale deploy/billing-service --replicas=0` → `BssDeploymentUnavailable`
  Firing sau ~1 phút + `group_wait` 30 giây (tổng ≲ 3 phút) → tin nhắn có `runbook_url`. Khôi phục:
  `kubectl -n bss scale deploy/billing-service --replicas=<số cũ>`.
- **Lỗi 5xx:** xem `bss-high-error-rate.md` mục 4.

# Runbook: kiểm tra logging + tracing (Giai đoạn 7, việc 2+3)

> Không phải runbook xử lý sự cố — đây là hướng dẫn **tự kiểm chứng** rằng log JSON, `trace_id`
> và trace phân tán đang hoạt động thật, dùng khi vừa cài (`logging-install.sh`,
> `tracing-install.sh`) hoặc sau khi đổi cấu hình OTel/Fluent Bit.

## 1. Log JSON + trace_id (không cần OTel Collector)

```bash
kubectl -n bss logs deploy/customer-service --tail=20
```

Mỗi dòng phải là **1 object JSON** (không phải text): `message`, `logger_name`, `level`,
`appName`. Khi dòng log đó phát sinh TRONG lúc xử lý 1 request (không phải log lúc khởi động),
sẽ có thêm `trace_id`/`span_id`/`trace_flags` — 2 trường này do OTel Java agent tự bơm vào MDC
(`OTEL_INSTRUMENTATION_LOGBACK_MDC_ENABLED=true`), **không phải code tự set**. Log lúc khởi động
(trước khi có request nào) sẽ KHÔNG có `trace_id` — đúng, không phải lỗi.

Nếu log vẫn là text (không phải JSON): kiểm `kubectl -n bss exec deploy/customer-service --
find / -name logback-spring.xml` — file phải nằm trong `BOOT-INF/classes/` của jar (build lại
image nếu vừa sửa `apps/backend/<svc>/src/main/resources/logback-spring.xml`).

## 2. Trace phân tán thật (cần `./scripts/tracing-install.sh kind` hoặc `dev|staging|prod`)

```bash
# Gọi 1 request thật qua gateway (ví dụ danh sách khách hàng)
curl -s "http://bss.localtest.me/api/tmf-api/customerManagement/v4/customer?limit=1" -o /dev/null

# Xem span nhận được (verbosity: detailed ở bản kind — xem toàn bộ attribute)
kubectl -n observability logs deploy/otel-collector --since=30s | grep -A5 "Span #"
```

Bằng chứng "đúng" (đã tự kiểm chứng thật, không phải suy đoán — xem PR Giai đoạn 7 việc 2+3): một
request GET customer qua gateway sinh ra **12 span cùng 1 Trace ID**, xâu chuỗi:

```
api-gateway   GET customer                         (root, không Parent ID)
  └ FilteringWebHandler.handle
      └ GET (gọi customer-service qua HTTP client của gateway)
          └ customer-service  GET /tmf-api/customerManagement/v4/customer
              └ CustomerController.list
                  ├ CustomerRepository.findAll
                  │   └ SELECT com.bss.customer.model.Customer  (Hibernate, ×2 — 1 cho `customer`, 1 cho `count`)
                  │       └ SELECT customer.customers            (JDBC thật)
                  └ Transaction.commit
```

Không cần sửa 1 dòng code Java nào — toàn bộ cây span trên tới từ OTel Java agent tự động
instrument Tomcat, Spring MVC, Reactor Netty (gateway), Hibernate, JDBC.

Nếu KHÔNG thấy span nào / thấy log lỗi `Failed to export spans ... Name or service not known`
trong `kubectl -n bss logs deploy/<svc>`: Service `otel-collector` chưa tồn tại đúng tên (kiểm
`kubectl -n observability get svc` — phải có `otel-collector`, không phải tên dài hơn do Helm tự
ghép; xem `fullnameOverride` trong `platform/tracing/otel-collector-values*.yaml`).

## 3. Fluent Bit — parser `cri` + Exclude_Path (B-17, B-42)

Dựng 1 sink cục bộ để soi log Fluent Bit gửi đi mà không cần CloudWatch (script không có sẵn
trong repo, tự viết theo mẫu bên dưới — hoặc đọc PR Giai đoạn 7 việc 2+3 để lấy file gốc):

```yaml
# webhook-sink.yaml — Pod Python http.server 8000, in mỗi POST nhận được ra log của chính nó
apiVersion: v1
kind: Pod
metadata: { name: webhook-sink, namespace: default, labels: { app: webhook-sink } }
spec:
  containers:
    - name: sink
      image: python:3.12-alpine
      command: ["python","-c","from http.server import *; H=type('H',(BaseHTTPRequestHandler,),{'do_POST':lambda s:(s.send_response(200),s.end_headers(),print('POST',s.rfile.read(int(s.headers.get('Content-Length',0))).decode()[:2000],flush=True))}); HTTPServer(('0.0.0.0',8000),H).serve_forever()"]
---
apiVersion: v1
kind: Service
metadata: { name: webhook-sink, namespace: default }
spec: { selector: { app: webhook-sink }, ports: [{ port: 8000, targetPort: 8000 }] }
```

```bash
kubectl apply -f webhook-sink.yaml
./scripts/logging-install.sh kind
sleep 15 && kubectl -n default logs webhook-sink --tail=3
```

Mỗi dòng log là **1 lớp JSON duy nhất** (không lồng nhau) với `kubernetes.namespace_name`,
`kubernetes.pod_name`, và field `data` chứa nguyên JSON log của app (đã tách field, KHÔNG còn
field `log` thô — `keepLog: Off`).

> ⚠️ **Xóa `webhook-sink` ngay sau khi kiểm tra xong.** Nó chạy trong cluster → tự in log →
> Fluent Bit tự đọc log đó → gửi lại cho chính nó → phình JSON theo cấp số nhân trong vài giây
> (lỗi thật gặp khi viết bài này — xem comment `Exclude_Path` trong
> `platform/logging/fluent-bit-values-local.yaml`, đã thêm loại trừ namespace `default`). Không
> để sink chạy lâu dài; nó không phải một phần của platform, chỉ để kiểm tra 1 lần.

Không thấy log nào tới sink: `kubectl -n amazon-cloudwatch logs daemonset/fluent-bit-aws-for-fluent-bit`
— tìm lỗi kết nối HTTP hoặc lỗi parse (`[error] [input:tail...]`).

## 4. Tự kiểm tra

1. Vì sao `trace_id` xuất hiện trong log JSON mà không có dòng code Java nào set nó?
2. Nếu đổi tên bản Helm release của OTel Collector từ "otel-collector" sang tên khác, app còn kết nối được không? Vì sao?
3. `Keep_Log Off` khác `Keep_Log On` thế nào trong dữ liệu gửi tới CloudWatch/sink — thử bật lại
   và so sánh dung lượng 1 bản ghi.

# 16 — Platform addons & Observability: Helm, ALB Controller, Karpenter, Secrets CSI, Prometheus Operator, Fluent Bit, OTel

> Mục tiêu bài: hiểu vai trò, cấu hình và điều kiện chạy của từng addon trong `platform/`, sửa B-40 → B-43,
> và dựng được **quan sát (observability) thật**: metrics có số, log có mặt, alert có người nhận.
> Thời lượng: 5h đọc + 10h lab. **Giai đoạn 2 (bản local) và 5, 7 (trên EKS).**

---

## 1. Helm — ôn nhanh (handout 10)

- **Chart** = gói template K8s + `values.yaml` mặc định. **Release** = một lần cài chart vào cluster (có tên, có version, rollback được).
- `helm upgrade --install <release> <repo>/<chart> -n <ns> -f values.yaml --set a.b=c` — idempotent (chưa có thì cài, có rồi thì nâng).
- Luôn **ghim version chart** (`--version x.y.z`) — không ghim thì mỗi lần cài có thể ra bản khác (giống cấm `:latest`).
- Chart từ OCI registry (Karpenter) không `helm repo add` được: dùng thẳng `helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version <v>` (B-42).
- Thứ tự cài có ý nghĩa: CRD trước, rồi controller, rồi object dùng CRD (`NodePool`, `PrometheusRule`, `ServiceMonitor`).

⚖️ Quản lý nhiều release: lệnh tay (hiện tại, [platform/README.md](../platform/README.md)) → `helmfile` → Terraform `helm_release` → ArgoCD. Ansible `kubernetes.core.helm` cũng làm được (bài 02 mục 5.7).

---

## 2. Bảng điều kiện chạy của từng addon

| Addon | Cần IAM? | Cần gì khác | Hiện trạng |
|---|---|---|---|
| **metrics-server** | Không | — | ❌ Không có trong danh sách (B-43) |
| AWS Load Balancer Controller | ✅ (policy JSON chính thức ~ELB/EC2/ACM/WAF) | `clusterName`, (khuyến nghị) `vpcId`, `region`; subnet có tag `kubernetes.io/role/elb` ✅ | ❌ không có role (B-35) |
| ExternalDNS | ✅ Route 53 | Một **hosted zone** bạn sở hữu; `txtOwnerId` | ❌ không role; chưa có domain → bỏ qua ở dev |
| Karpenter | ✅ controller role + SQS interruption + EventBridge rules | `settings.clusterName`, `settings.interruptionQueue`, CRD; tag discovery ✅ | ❌ (B-35, B-42) |
| Secrets Store CSI + AWS provider | Dùng IRSA **của Pod app** | SPC mỗi service; Pod phải mount volume CSI | 🟡 mẫu 1 service (B-20) |
| EBS CSI (EKS addon) | ✅ `AmazonEBSCSIDriverPolicy` | StorageClass `gp3` | ❌ (B-41) |
| Fluent Bit | ✅ `logs:PutLogEvents`... | Log group đã có (Terraform) | ❌ role; parser sai (B-42) |
| OTel Collector | ✅ `xray:PutTraceSegments`... | App phải gửi trace (Java agent) | ❌ |
| kube-prometheus-stack | Không (trừ remote write) | PVC (EBS CSI + StorageClass), ServiceMonitor | ❌ không ServiceMonitor (B-40) |

---

## 3. Networking addons

🔍 [aws-load-balancer-controller-values.yaml](../platform/networking/aws-load-balancer-controller-values.yaml) — 2 replica + PDB (controller quan trọng: chết thì Ingress mới không được xử lý), resource vừa phải, SA `aws-load-balancer-controller` chờ gắn IRSA.

🧠 Controller làm gì: theo dõi (watch) object `Ingress`/`Service` → gọi API AWS tạo ALB, listener, rule, target group; với `target-type: ip` đăng ký **IP Pod** vào target group và cập nhật khi Pod đổi. Trạng thái hiện ở `kubectl describe ingress bss-ingress` (Events) — nơi đầu tiên xem khi "không có ALB".

🔍 [external-dns-values.yaml](../platform/networking/external-dns-values.yaml) — `policy: sync` (xóa record khi xóa Ingress — ⚖️ `upsert-only` an toàn hơn), `sources: service, ingress`, `txtOwnerId` để đánh dấu record "của cluster này" (không đụng record người khác).

🔍 [karpenter-nodepool.yaml](../platform/networking/karpenter-nodepool.yaml)

| Trường | Ý nghĩa |
|---|---|
| `EC2NodeClass.amiFamily: AL2023` | Hệ điều hành node |
| `role: bss-dev-eks-node` | IAM role gắn vào node (dùng chung role node group — ⚠️ viết cứng `bss-dev` → staging/prod cần bản riêng) |
| `subnetSelectorTerms / securityGroupSelectorTerms` theo tag `karpenter.sh/discovery` | Terraform đã gắn tag ✅ |
| `blockDeviceMappings` 50Gi gp3 mã hóa | Ổ root |
| `NodePool.requirements`: amd64, linux, `capacity-type: spot, on-demand`, họ `t`/`m`, thế hệ > 2 | Karpenter chọn loại máy rẻ nhất thỏa yêu cầu Pod, ưu tiên spot |
| `expireAfter: 720h` | Thay node sau 30 ngày (vá bảo mật tự nhiên) — ⚠️ comment ghi "weekly" nhưng 720h là 30 ngày |
| `limits: cpu 100, memory 200Gi` | Trần tổng tài nguyên Karpenter được tạo — 💰 với dev nên hạ nhiều (vd. cpu 8) để chặn "hóa đơn bất ngờ" |
| `consolidationPolicy: WhenEmptyOrUnderutilized`, `consolidateAfter: 30s` | Gom Pod, xóa node thừa |

🔁 Handout 11 nói **Cluster Autoscaler** (scale Auto Scaling Group có sẵn, loại máy cố định). ⚖️ Karpenter tạo EC2 trực tiếp theo nhu cầu từng Pod (chọn loại máy linh hoạt, nhanh hơn, gom node tốt hơn); đổi lại cấu hình IAM/interruption phức tạp hơn và gắn chặt AWS.

---

## 4. Secrets Store CSI

🔍 [secrets-store-csi-values.yaml](../platform/secrets/secrets-store-csi-values.yaml): `syncSecret.enabled` (cho phép tạo K8s Secret từ secret mount), `enableSecretRotation` + `rotationPollInterval: 60s` (Secret Manager đổi → file trong Pod đổi; ⚠️ **biến môi trường thì không đổi** cho tới khi Pod restart).

🔍 [customer-secrets-spc.yaml](../platform/secrets/customer-secrets-spc.yaml): `SecretProviderClass` provider `aws`, lấy secret `bss-dev/rds/master`, `jmesPath` bóc `username/password/host` thành 3 "file"; `secretObjects` tạo K8s Secret `customer-db-credentials`.

Luồng đúng (còn thiếu phần in đậm trong Deployment):

```yaml
spec:
  serviceAccountName: customer-service          # IRSA role có secretsmanager:GetSecretValue
  volumes:
    - name: db-secrets
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes: { secretProviderClass: customer-db-credentials }
  containers:
    - volumeMounts: [{ name: db-secrets, mountPath: /mnt/secrets, readOnly: true }]
      # khi volume được mount, driver mới tạo K8s Secret customer-db-credentials → env secretKeyRef dùng được
```

⚠️ Dùng tài khoản **master** cho service (B-21). ⚖️ So với External Secrets Operator: ESO tạo Secret **không cần Pod mount**, cấu hình theo `ExternalSecret` — nhiều đội chọn ESO vì đơn giản hơn.

---

## 5. Metrics: kube-prometheus-stack

### 5.1 Bức tranh

```
[App Pod /actuator/prometheus] ◀─scrape─ Prometheus ◀─ cấu hình sinh bởi ─ Prometheus Operator ◀─ ServiceMonitor/PodMonitor (CRD)
[node-exporter DaemonSet]      ◀─scrape─┘                                  ◀─ PrometheusRule (CRD) → rule alert
[kube-state-metrics]           ◀─scrape─┘
Prometheus ──alert──▶ Alertmanager ──▶ Slack/Discord/Email
Grafana ──query PromQL──▶ Prometheus
```

🔁 Handout 16: "3 cách deploy: tự làm / Operator / Helm" — kube-prometheus-stack là **Helm cài Operator**. Handout cũng có bước "deploy **ServiceMonitor** để Prometheus biết target mới" — đó là mảnh dự án đang thiếu.

### 5.2 Vì sao annotation của bạn không chạy ở đây (B-40)

- Đồ án: Prometheus "thường" có `scrape_configs` với `kubernetes_sd_configs: role: pod` + `relabel_configs` giữ Pod có `prometheus.io/scrape="true"`. Annotation chỉ có nghĩa **vì bạn viết relabel đó**.
- kube-prometheus-stack: Operator **tự sinh** cấu hình từ ServiceMonitor/PodMonitor; không có job nào đọc annotation. `serviceMonitorSelectorNilUsesHelmValues: false` (trong values) chỉ có nghĩa "chọn ServiceMonitor ở mọi namespace/nhãn" — vẫn cần **có** ServiceMonitor.

Mẫu (đặt trong base, dùng chung cho 5 backend nhờ nhãn `tier: backend`):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: bss-backend
  namespace: bss
spec:
  selector:
    matchLabels: { tier: backend }        # ⚠️ Service hiện chỉ có nhãn app: ... → thêm tier: backend vào Service
  namespaceSelector: { matchNames: [bss] }
  endpoints:
    - port: http                          # tên port trong Service
      path: /actuator/prometheus
      interval: 30s
```

Sau khi áp: Prometheus UI → Status → Targets thấy 5 target `UP`; nhãn `namespace`, `pod`, `service`, `job` được Operator gắn tự động.

### 5.3 Values — những dòng đáng chú ý

🔍 [prometheus/values.yaml](../platform/monitoring/prometheus/values.yaml)

| Dòng | Cấu hình | Ghi chú |
|---|---|---|
| 10–11 | retention 10 ngày / 8GB | Cái nào tới trước thì xóa dữ liệu cũ |
| 18–19 | `...SelectorNilUsesHelmValues: false` | Chọn mọi ServiceMonitor/PodMonitor |
| 20–27, 64–71 | PVC `storageClassName: gp3` | ⚠️ StorageClass `gp3` chưa tồn tại (B-41) — tạo SC hoặc dùng mặc định; ở kind dùng `standard` |
| 32 | `adminPassword: CHANGE_ME` | ⚠️ mật khẩu trong git → dùng `admin.existingSecret` |
| 45–60 | Sidecar dashboard (label `grafana_dashboard=1`) **và** `dashboardsConfigMaps` | Hai cơ chế nạp dashboard cùng lúc → chọn một (sidecar như README) |
| 76–88 | Alertmanager route + receiver `default` rỗng | ⚠️ alert không đi đâu — cấu hình receiver qua Secret (`alertmanager.config` + `existingSecret`) |
| 90–95 | Tắt rule etcd/scheduler/controller-manager/kube-proxy | Đúng — control plane EKS do AWS quản, không scrape được |

### 5.4 Alert — đọc PromQL từng rule

🔍 [bss-alerts.yaml](../platform/monitoring/alerts/bss-alerts.yaml) — nhãn `release: monitoring` để Operator chọn rule (khớp tên release Helm).

| Alert | PromQL | Đọc thành lời |
|---|---|---|
| BssServiceDown | `up{namespace="bss"} == 0` for 2m | Target scrape thất bại liên tục 2 phút. ⚠️ Không có target (B-40) → `up` không tồn tại → **không bao giờ bắn**. Thêm alert `absent(up{job=~"bss.*"})` để bắt "mất hẳn" |
| BssHighRequestLatency | `histogram_quantile(0.95, sum by (le, application, uri)(rate(..._bucket[5m]))) > 1` for 10m | p95 độ trễ theo từng endpoint > 1s. ⚠️ Cần histogram (B-16) |
| BssHighErrorRate | tỉ lệ `rate(count{status=~"5.."})` / `rate(count)` theo `application` > 5% for 5m | ⚠️ Cần tag `application` cho mọi service (B-16) |
| BssPodCrashLooping | `rate(kube_pod_container_status_restarts_total[15m]) > 0` for 10m | Có restart liên tục (kube-state-metrics) |
| BssJvmHeapHigh | heap used / heap max > 85% for 15m | ⚠️ `jvm_memory_max_bytes` có thể = -1 với vài vùng nhớ → lọc `area="heap"` là đúng |

🧠 PromQL tối thiểu: `rate(counter[5m])` = tốc độ tăng/giây trung bình 5 phút (chỉ dùng với **counter**); `sum by (label)` gộp theo nhãn; `histogram_quantile(q, sum by (le) (rate(bucket[5m])))` tính phân vị từ histogram — **luôn giữ `le`** trong `by`.

⚠️ Mọi alert thiếu annotation `runbook_url` (CLAUDE.md §10 bắt buộc) → viết `docs/runbooks/bss-high-error-rate.md`...

### 5.5 Dashboard

🔍 [bss-overview.json](../platform/monitoring/grafana/dashboards/bss-overview.json) — 8 panel: Request rate, p95, 5xx rate, Pods ready, Rate theo endpoint, p50/95/99, JVM heap, CPU container. Đây là **RED** (Rate, Errors, Duration) + saturation (heap, CPU). Biến `$application` lọc service.

### 5.6 SLO (Giai đoạn 7)

- SLI: tỉ lệ request không phải 5xx. SLO: 99.5%/30 ngày → **error budget** 0.5% ≈ 3.6 giờ lỗi toàn phần/tháng.
- Alert theo **burn rate** nhiều cửa sổ (SRE Workbook): đốt ngân sách nhanh (14.4× trong 1h) → gọi người; chậm (6× trong 6h) → tạo ticket. Hiệu quả hơn ngưỡng cứng "5xx > 5%".

---

## 6. Logs: Fluent Bit → CloudWatch

🔍 [fluent-bit-values.yaml](../platform/logging/fluent-bit-values.yaml)

- DaemonSet (1 pod/node) đọc `/var/log/containers/*.log`, bỏ log `kube-system` và chính nó, filter `kubernetes` gắn metadata (namespace, pod, label), `mergeLog: true` (nếu log là JSON thì tách thành trường).
- ⚠️ `parser: docker` — EKS dùng **containerd**, dòng log dạng CRI (`<time> stdout F <message>`) → phải dùng parser `cri` (hoặc multiline parser `cri` của Fluent Bit mới) (B-42).
- `autoCreateGroup: false` + `logGroupName: /aws/eks/CHANGE_ME_CLUSTER/application` → khớp log group Terraform tạo.
- `tolerations: Exists` + `priorityClassName: system-node-critical` → chạy trên mọi node, ưu tiên cao.
- Log app đang là text (B-17) → `mergeLog` không tách được trường. Chuyển sang JSON để CloudWatch Logs Insights truy vấn `fields level, trace_id | filter level = "ERROR"`.
- 💰 CloudWatch tính phí **ingest theo GB** — lọc log DEBUG ở prod.

⚖️ Thay thế in-cluster: Loki + Grafana (rẻ, tích hợp Grafana) — hợp với "Prometheus làm nguồn sự thật" của dự án; CloudWatch hợp khi cần tích hợp AWS/không muốn vận hành thêm.

---

## 7. Traces: OpenTelemetry → X-Ray

🔍 [otel-collector-values.yaml](../platform/tracing/otel-collector-values.yaml)

```
receivers:  otlp (gRPC 4317, HTTP 4318)        ← app gửi trace chuẩn OTLP
processors: memory_limiter → batch             ← chống OOM, gom lô
exporters:  awsxray                            ← đẩy lên X-Ray (cần IAM)
pipelines:  traces: [otlp] → [memory_limiter, batch] → [awsxray]
```

Còn thiếu phía app: gắn **OpenTelemetry Java agent** (không sửa code) — thêm init container copy `opentelemetry-javaagent.jar` vào volume chung, env `JAVA_TOOL_OPTIONS=-javaagent:/otel/opentelemetry-javaagent.jar`, `OTEL_SERVICE_NAME=customer-service`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability:4318`, `OTEL_PROPAGATORS=tracecontext,baggage,xray`. ⚠️ Trace **không tự đi qua SQS**: cần truyền trace context trong message attributes để thấy một trace liền mạch order → billing (thử thách nâng cao).

⚖️ Thay thế in-cluster: Grafana Tempo/Jaeger (miễn phí, cùng hệ Grafana).

---

## 8. Labs

| Lab | Nội dung | Lỗi | Đạt khi |
|---|---|---|---|
| 16.1 | (kind) Cài metrics-server + kube-prometheus-stack (values local: SC `standard`, password từ Secret) | B-41, B-42, B-43 | Grafana mở được qua port-forward |
| 16.2 | Thêm nhãn `tier: backend` cho Service + ServiceMonitor | B-40 | 5 target UP |
| 16.3 | Bật histogram + tag `application` (lab 10.11) → dashboard có số | B-16 | Panel p95 có dữ liệu |
| 16.4 | Áp `bss-alerts.yaml`; cố tình trả 500 (endpoint thử) → alert Firing | — | Thấy alert trong Alertmanager |
| 16.5 | Alertmanager → Discord/Slack webhook (qua Secret); thêm `runbook_url` + viết 1 runbook | B-42 | Nhận tin nhắn |
| 16.6 | Dùng k6 tạo tải → HPA scale (quan sát `kubectl get hpa -w`) | — | Số pod tăng rồi giảm sau 5 phút |
| 16.7 | (EKS) Cài ALB Controller với role từ `platform-iam` | B-35 | Ingress có địa chỉ ALB |
| 16.8 | (EKS) Secrets CSI cho 4 service + DB user riêng | B-20, B-21 | Pod Running không dùng master |
| 16.9 | (EKS) Fluent Bit parser `cri` + log JSON; truy vấn Logs Insights | B-17, B-42 | Tìm được log theo `trace_id` |
| 16.10 | (Nâng cao) OTel Java agent + X-Ray service map | — | Thấy gateway → order → (…) |

## 9. Tự kiểm tra

1. Vì sao `prometheus.io/scrape` chạy trong đồ án nhưng không chạy với kube-prometheus-stack?
2. Viết PromQL tính tỉ lệ 5xx của `order-management` trong 5 phút.
3. Vì sao phải giữ `le` trong `sum by (...)` trước `histogram_quantile`?
4. Karpenter khác Cluster Autoscaler ở cơ chế nào? Trade-off?
5. Secrets CSI: vì sao Pod không mount volume thì K8s Secret không được tạo?
6. Parser `docker` và `cri` khác nhau thế nào? Vì sao EKS cần `cri`?
7. Error budget của SLO 99.9%/30 ngày là bao nhiêu phút?

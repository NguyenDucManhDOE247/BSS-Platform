# 13 — Kubernetes manifests & Kustomize 3 môi trường

> Mục tiêu bài: giải thích được **mọi trường** trong manifest của dự án, hiểu Kustomize ghép base + overlay ra sao,
> dựng toàn hệ thống trên **kind** (K8s local, miễn phí), và sửa B-20 → B-25.
> Thời lượng: 4h đọc + 10h lab. **Giai đoạn 2.**

---

## 1. Ôn nhanh K8s (handout 10) và đồ án của bạn

| Khái niệm | Đồ án OSM | BSS Platform |
|---|---|---|
| Namespace | `osm`, `osm-dev`, `monitoring`, `ingress-nginx` | `bss` (mỗi môi trường một **cluster** riêng) |
| Config | ConfigMap `osm-config`, Secret `osm-secrets` | ConfigMap sinh bởi Kustomize (có hash), Secret từ Secrets Manager qua CSI (chưa hoàn thiện — B-20) |
| Probe | liveness + readiness | **startup** + liveness + readiness |
| Scale | HPA CPU 70% / Mem 80%, 2→5 | HPA CPU 70% / Mem 80%, 2→10 (gateway 60%, 2→12) + **PDB** |
| Entry | NGINX Ingress + NLB | Ingress class `alb` → AWS ALB |
| Quyền AWS của Pod | Node role | **IRSA** — mỗi ServiceAccount một IAM Role |
| Đóng gói manifest | YAML thuần + `namespace-dev.yaml` | **Kustomize** base + overlays |

---

## 2. Base của một service — đọc từng trường

### 2.1 Deployment

🔍 [base/customer-service/deployment.yaml](../infrastructure/kubernetes/base/customer-service/deployment.yaml)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: customer-service
  namespace: bss
  labels: { app: customer-service, tier: backend, tm-forum-api: tmf629 }   # label để lọc/tổ chức
spec:
  replicas: 2                        # overlay sẽ đổi; ⚠️ HPA ghi đè khi tồn tại (B-22)
  selector:
    matchLabels: { app: customer-service }   # BẤT BIẾN sau khi tạo — Deployment quản Pod có label này
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1                    # được tạo thêm tối đa 1 pod mới vượt số replicas
      maxUnavailable: 0              # không bao giờ giảm dưới số replicas → zero-downtime (cần đủ tài nguyên cho pod dư)
  template:                          # "khuôn" Pod
    metadata:
      labels: { app: customer-service, tier: backend }
      annotations:                   # ⚠️ Prometheus Operator KHÔNG đọc các annotation này (B-40)
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/actuator/prometheus"
    spec:
      serviceAccountName: customer-service   # danh tính của Pod → IRSA
      topologySpreadConstraints:
        - maxSkew: 1                         # chênh lệch số pod giữa các AZ tối đa 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway  # "cố gắng" chứ không bắt buộc (DoNotSchedule = bắt buộc)
          labelSelector: { matchLabels: { app: customer-service } }
      containers:
        - name: app
          image: customer-service:latest     # placeholder — Kustomize `images:` thay bằng ECR + tag
          ports: [{ containerPort: 8080, name: http }]
          env:
            - { name: SPRING_PROFILES_ACTIVE, value: "aws" }
            - name: DB_URL
              valueFrom: { configMapKeyRef: { name: customer-service-config, key: DB_URL } }
            - name: DB_USER
              valueFrom: { secretKeyRef: { name: customer-db-credentials, key: username } }   # ⚠️ Secret chưa ai tạo (B-20)
            - name: DB_PASSWORD
              valueFrom: { secretKeyRef: { name: customer-db-credentials, key: password } }
          startupProbe:                      # chỉ chạy lúc khởi động; khi pass mới bắt đầu liveness/readiness
            httpGet: { path: /actuator/health/liveness, port: 8080 }
            failureThreshold: 30             # 30 × 5s = cho JVM tối đa 150s để khởi động
            periodSeconds: 5
          livenessProbe:                     # fail → kubelet RESTART container
            httpGet: { path: /actuator/health/liveness, port: 8080 }
            periodSeconds: 10
          readinessProbe:                    # fail → rút Pod khỏi Service endpoints (không restart)
            httpGet: { path: /actuator/health/readiness, port: 8080 }
            periodSeconds: 5
          resources:
            requests: { cpu: 250m, memory: 512Mi }   # scheduler dùng để xếp Pod vào node; HPA tính % theo request
            limits:   { cpu: 1000m, memory: 1Gi }    # vượt CPU → bị bóp (throttle); vượt memory → OOMKilled
          securityContext:
            runAsNonRoot: true               # từ chối chạy nếu UID = 0
            runAsUser: 1000
            allowPrivilegeEscalation: false  # chặn setuid/sudo
            readOnlyRootFilesystem: true     # không ghi được vào filesystem của image
            capabilities: { drop: ["ALL"] }  # bỏ mọi quyền kernel đặc biệt
          volumeMounts: [{ name: tmp, mountPath: /tmp }]   # Tomcat cần /tmp ghi được → emptyDir
      volumes: [{ name: tmp, emptyDir: {} }]
```

🧠 **Ba probe — khi nào dùng cái nào** (lỗi hay gặp nhất khi phỏng vấn):

| Probe | Câu hỏi nó trả lời | Khi fail | Sai lầm kinh điển |
|---|---|---|---|
| startup | "Đã khởi động xong chưa?" | Restart (sau `failureThreshold`) | Không có startup → liveness giết JVM đang khởi động → CrashLoopBackOff |
| liveness | "Còn sống hay treo cứng?" | **Restart** container | Cho liveness kiểm tra DB → DB chậm là restart **toàn bộ** Pod → sự cố lan rộng |
| readiness | "Có nhận traffic được không?" | Rút khỏi Service, không restart | — |

Spring Boot tách sẵn: `/actuator/health/liveness` (trạng thái nội bộ app) và `/readiness` (app sẵn sàng phục vụ). DB **không** nằm trong nhóm liveness mặc định — đúng thiết kế.

🧠 **Tính memory cho JVM:** limit 1Gi × `MaxRAMPercentage=75` → heap tối đa ~768Mi; ~256Mi còn lại cho metaspace, thread stack, buffer. Request 512Mi = "đặt chỗ" trên node. Nếu request quá thấp so với dùng thật, node bị nhồi quá tải → OOM ở cấp node.

### 2.2 Service, ServiceAccount, HPA, PDB

🔍 [service.yaml](../infrastructure/kubernetes/base/customer-service/service.yaml) — `ClusterIP`, `port: 80 → targetPort: 8080`, selector `app: customer-service`. DNS: `customer-service.bss.svc.cluster.local` (gateway gọi tên này).

🔍 [serviceaccount.yaml](../infrastructure/kubernetes/base/customer-service/serviceaccount.yaml) — rỗng ở base; overlay thêm annotation `eks.amazonaws.com/role-arn` (khác nhau mỗi môi trường vì account/role khác).

🔍 [hpa.yaml](../infrastructure/kubernetes/base/customer-service/hpa.yaml)
- `autoscaling/v2`, `minReplicas: 2`, `maxReplicas: 10`, CPU 70% **của request** (250m → scale khi trung bình > 175m), memory 80%.
- `behavior.scaleDown.stabilizationWindowSeconds: 300` — chờ 5 phút ổn định mới giảm pod (chống "dao động").
- ⚠️ Cần **metrics-server** (B-43). ⚖️ Scale theo memory với JVM thường vô nghĩa — JVM giữ heap đã cấp, memory ít khi giảm → HPA không bao giờ scale down. Cân nhắc bỏ metric memory.

🔍 [pdb.yaml](../infrastructure/kubernetes/base/customer-service/pdb.yaml) — `minAvailable: 1`: khi **tự nguyện** gián đoạn (drain node, Karpenter gom node, nâng cấp) phải còn ≥1 pod. ⚠️ Nếu replicas = 1 và `minAvailable: 1` → **không drain được node** (Karpenter/nâng cấp bị kẹt). Dev 1 replica cần PDB `maxUnavailable: 1` hoặc bỏ PDB.

### 2.3 Namespace & Ingress

🔍 [namespace.yaml](../infrastructure/kubernetes/base/namespace.yaml) — chưa có nhãn Pod Security (`pod-security.kubernetes.io/enforce: restricted`) — dự án đã đủ securityContext để bật (B-25).

🔍 [ingress.yaml](../infrastructure/kubernetes/base/ingress.yaml)

| Annotation / trường | Ý nghĩa |
|---|---|
| `kubernetes.io/ingress.class: alb` | Chọn ALB Controller (cú pháp cũ → nên dùng `spec.ingressClassName: alb`) |
| `alb.ingress.kubernetes.io/scheme: internet-facing` | ALB public (đặt ở subnet có tag `kubernetes.io/role/elb`) |
| `target-type: ip` | ALB gửi thẳng tới **IP của Pod** (nhờ VPC CNI Pod có IP thật trong VPC) — không qua NodePort |
| `listen-ports: HTTP 80, HTTPS 443` + `ssl-redirect: '443'` | ⚠️ Cần certificate ACM; không có → không tạo được ALB (B-23) |
| `healthcheck-path: /actuator/health` | Áp cho mọi target group — với Nginx, path này rơi vào SPA fallback nên vẫn trả 200 (may mắn). Tốt hơn: đặt annotation healthcheck riêng trên từng Service |
| rules `/api` → api-gateway, `/admin` → admin-console, `/` → web-portal | `pathType: Prefix`; ALB ưu tiên rule cụ thể hơn. ⚠️ `/admin` + asset (B-06) |
| `host: REPLACE_ME_HOST` | Overlay thay bằng `dev.bss.example.com` — domain không phải của bạn |

---

## 3. Kustomize — cơ chế ghép

### 3.1 Cây kustomization

```
overlays/dev/kustomization.yaml
  resources: [../../base]
        base/kustomization.yaml
          resources: [namespace.yaml, customer-service/, product-catalog/, ..., ingress.yaml]
                customer-service/kustomization.yaml
                  namespace: bss
                  resources: [serviceaccount, deployment, service, hpa, pdb]
                  commonLabels: {app.kubernetes.io/part-of: bss-platform, app.kubernetes.io/name: customer-service}
```

Chạy thử (máy bạn có sẵn trong kubectl): `kubectl kustomize infrastructure/kubernetes/overlays/dev`. Tôi đã chạy: cả 3 overlay build thành công, **41 object** mỗi môi trường (1 Namespace, 7 Deployment, 7 Service, 7 ServiceAccount, 7 HPA, 7 PDB, 4 ConfigMap, 1 Ingress) — **0 Secret**.

⚠️ `commonLabels` (deprecated) thêm nhãn vào **cả selector** — đổi giá trị về sau → `kubectl apply` lỗi "field is immutable". Dùng `labels:` với `includeSelectors: false`.

### 3.2 Overlay dev — từng khối

🔍 [overlays/dev/kustomization.yaml](../infrastructure/kubernetes/overlays/dev/kustomization.yaml)

| Khối | Cơ chế | Kết quả |
|---|---|---|
| `images:` | *Image transformer*: mọi container có `image: customer-service` → đổi thành `newName:newTag` | `CHANGE_ME.dkr.ecr.../bss/customer-service:dev`. CD dùng `kustomize edit set image` để sửa chỗ này (B-50) |
| `configMapGenerator:` | Sinh ConfigMap từ literal, **tên có hậu tố hash** (vd. `customer-service-config-45gbfkc4bm`) và **tự sửa mọi tham chiếu** trong Deployment | Đổi 1 giá trị → tên mới → Pod template đổi → **tự rolling restart**. (ConfigMap thường thì đổi xong Pod không biết) |
| `replicas:` | Đặt `spec.replicas` | ⚠️ HPA ghi đè (B-22) |
| `patches:` JSON6902 cho ServiceAccount | `op: add path: /metadata/annotations` | Thêm IRSA role ARN |
| patch Ingress | `op: replace /spec/rules/0/host` + `add /metadata/annotations/external-dns.alpha.kubernetes.io~1hostname` | `~1` là cách viết `/` trong JSON Pointer (vì `/` là dấu phân cấp) |

Lưu ý: ConfigMap dev chứa `SPRING_PROFILES_ACTIVE`, `LOG_LEVEL`, `AWS_REGION` nhưng Deployment chỉ đọc **key `DB_URL`** (và `AWS_REGION/EVENT_BUS_NAME/SQS_QUEUE_URL` cho order/billing) → `LOG_LEVEL=DEBUG` **không có tác dụng** (không ai đọc; Spring cũng không hiểu biến `LOG_LEVEL`). Cách đúng: `envFrom: configMapRef` + đặt tên biến Spring hiểu (`LOGGING_LEVEL_ROOT=DEBUG`).

### 3.3 Staging & prod khác gì

- staging: tag `rc`, `LOG_LEVEL=INFO`, replicas 2, role/queue/bus `bss-staging-*`, host `staging.bss.example.com`.
- prod: tag `v0.0.0`, replicas 3, **PDB `minAvailable: 2`** cho 5 backend, request CPU 500m / memory 768Mi cho 4 service nghiệp vụ.
- ⚖️ Ba overlay lặp ~90% nội dung → dùng **Kustomize component** hoặc một overlay chung `aws/` để giảm lặp.

### 3.4 Kustomize vs Helm (bạn sẽ dùng cả hai)

| | Kustomize (apps) | Helm (platform addons) |
|---|---|---|
| Cách làm | YAML thật + patch | Template Go + `values.yaml` |
| Đọc hiểu | Dễ — thấy gì chạy nấy | Khó hơn khi template phức tạp |
| Tham số hóa | Hạn chế (patch) | Mạnh (if/range/function) |
| Phiên bản & rollback | Không có khái niệm release | `helm history`, `helm rollback` |
| Chia sẻ cho người khác | Kém | Chart repo (Artifact Hub) |

---

## 4. Tính "ngân sách pod" cho dev (B-22)

EKS với VPC CNI giới hạn số pod/node theo ENI: `t3.medium` = 3 ENI × (6 IP − 1) + 2 = **17 pod/node**.

| Nhóm | Pod (ước tính, 2 node) |
|---|---|
| Hệ thống: aws-node ×2, kube-proxy ×2, coredns ×2, ebs-csi (controller ×2 + node ×2) | ~10 |
| Addon: ALB controller ×2, metrics-server, Secrets CSI ×2 + provider ×2, Fluent Bit ×2, OTel, Karpenter ×2 | ~13 |
| Monitoring: operator, prometheus, alertmanager, grafana, kube-state-metrics, node-exporter ×2 | ~7 |
| App (HPA min 2 × 7) | **14** |
| **Tổng** | **~44 > 34** → Pod `Pending` |

Memory còn tệ hơn: 5 backend × 2 × 512Mi = 5Gi request, trong khi 2 × t3.medium chỉ có ~6.6 GiB allocatable cho mọi thứ. Giải pháp: dev `minReplicas: 1`, bỏ bớt addon ở dev, bật **prefix delegation** của VPC CNI (tăng số pod/node), hoặc để Karpenter thêm node (tốn tiền). Đây là bài tập "capacity planning" rất thật.

---

## 5. Secret cho DB — chọn hướng (B-20, B-21)

| Hướng | Local (kind) | AWS | ⚖️ |
|---|---|---|---|
| `secretGenerator` của Kustomize từ file `.env` không commit | ✅ đơn giản | ❌ secret nằm trên máy người deploy | Chỉ dùng local |
| **Secrets Store CSI** + `secretObjects` (repo chọn) | — | ✅ | Pod **phải mount** volume CSI thì secret mới được sync; mỗi service một SPC |
| **External Secrets Operator** | — | ✅ | Sync Secrets Manager → K8s Secret độc lập với Pod (không có vấn đề "phải mount"); phổ biến trong ngành |
| RDS IAM auth (token 15 phút) | — | ✅ | Không cần password; phức tạp hơn với JDBC |

Cho B-21: K8s **Job** `db-bootstrap` chạy `psql` bằng tài khoản master, tạo 4 DB + 4 user riêng + GRANT; mật khẩu từng user lưu Secrets Manager (Terraform `random_password` × 4).

---

## 6. Chạy toàn hệ thống trên kind (Giai đoạn 2)

Mục tiêu: học K8s **miễn phí** trước khi đụng EKS. Đề xuất tạo `overlays/local/`:

```
overlays/local/
├── kustomization.yaml     resources: ../../base + postgres/ + localstack/
│                          images: newName bss/<svc>, newTag: local (image build ở máy, nạp bằng `kind load docker-image`)
│                          secretGenerator: *-db-credentials từ file .env (gitignore)
│                          patches: replicas 1, HPA min 1, Ingress class nginx + host bss.localtest.me, bỏ annotation IRSA
├── postgres/              StatefulSet + PVC + Service + ConfigMap chứa init script tạo 4 DB  (🔁 handout 10 StatefulSet)
└── localstack/            Deployment + Service + ConfigMap init script
```

Các bước chính:
1. `kind create cluster --config kind.yaml` (map port 80/443 cho ingress).
2. Cài **ingress-nginx** (🔁 bạn đã biết từ đồ án — dùng cho local vẫn tốt) và **metrics-server** (kind cần cờ `--kubelet-insecure-tls`).
3. Build 7 image với tag `local` → `kind load docker-image`.
4. `kubectl apply -k infrastructure/kubernetes/overlays/local` → `kubectl -n bss get pods -w`.
5. Chạy `scripts/e2e-local.sh` trỏ tới `http://bss.localtest.me/api`.

`*.localtest.me` luôn phân giải về 127.0.0.1 — không cần sửa file hosts.

---

## 7. Bộ công cụ debug (thuộc lòng)

```bash
kubectl -n bss get pods -o wide                   # trạng thái + node + IP
kubectl -n bss describe pod <pod>                 # Events cuối: Pending vì sao, pull image lỗi gì
kubectl -n bss logs <pod> [--previous]            # log lần chạy trước khi crash
kubectl -n bss get events --sort-by=.lastTimestamp
kubectl -n bss exec -it <pod> -- sh               # (image JRE jammy có sh; distroless thì không)
kubectl -n bss port-forward svc/customer-service 8081:80
kubectl -n bss rollout status|history|undo deploy/customer-service
kubectl -n bss get hpa                            # <unknown> → thiếu metrics-server
kubectl -n bss get endpoints customer-service     # rỗng → selector sai hoặc readiness fail
```

| Triệu chứng | Nguyên nhân thường gặp trong dự án này |
|---|---|
| `CreateContainerConfigError` | Secret/ConfigMap không tồn tại (B-20) |
| `ImagePullBackOff` | tag `CHANGE_ME...:dev` (B-50), thiếu quyền ECR, sai tên repo |
| `CrashLoopBackOff` | Không kết nối được DB, Flyway lỗi, `ddl-auto validate` lệch |
| `Pending` | Thiếu CPU/memory/pod slot (B-22), PVC chưa bound (B-41) |
| Pod Running nhưng 503 từ ALB | readiness fail, Service selector sai |

---

## 8. Labs

| Lab | Nội dung | Lỗi | Đạt khi |
|---|---|---|---|
| 13.1 | Tự viết Deployment + Service + ConfigMap cho customer-service **không nhìn** base; diff với base | — | Liệt kê được 5 thứ bạn quên |
| 13.2 | Tạo cluster kind + ingress-nginx + metrics-server | B-43 | `kubectl top nodes` có số |
| 13.3 | Viết `overlays/local` (Postgres StatefulSet, LocalStack, secretGenerator, HPA min 1) | B-20, B-22 | 7 service Ready |
| 13.4 | E2E qua ingress local | — | script PASS |
| 13.5 | Probe lab: bỏ startupProbe + liveness `initialDelaySeconds: 1` → quan sát CrashLoop; khôi phục | — | Giải thích được trong nhật ký |
| 13.6 | Đổi 1 literal trong configMapGenerator → quan sát tên ConfigMap mới + rolling restart | — | — |
| 13.7 | Đổi `commonLabels` → `labels`; `ingressClassName`; dùng `envFrom` + `LOGGING_LEVEL_ROOT` | B-24 | `kubectl kustomize` sạch warning |
| 13.8 | Gắn nhãn PSS `restricted` cho namespace; thử deploy Pod thiếu securityContext → bị từ chối | B-25 | Thấy thông báo reject |
| 13.9 | Patch dev: Ingress chỉ HTTP; PDB phù hợp 1 replica | B-23 | Build dev sạch |

## 9. Tự kiểm tra

1. `maxSurge: 1, maxUnavailable: 0` với 3 replica: quá trình rolling update diễn ra thế nào? Cần thêm tài nguyên gì?
2. Vì sao liveness không nên kiểm tra DB?
3. Kustomize sửa tên ConfigMap có hash — vì sao việc này có lợi?
4. HPA và `replicas:` trong overlay — cái nào thắng? Vì sao?
5. PDB `minAvailable: 1` với 1 replica gây hậu quả gì khi Karpenter muốn gom node?
6. `target-type: ip` khác `instance` thế nào?

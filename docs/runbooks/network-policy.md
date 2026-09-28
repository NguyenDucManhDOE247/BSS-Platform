# Runbook: NetworkPolicy — vá lỗi kết nối, tự kiểm chứng enforcement (Giai đoạn 7, việc 5 — B-25)

## 1. Bức tranh chung

5 file trong `infrastructure/kubernetes/base/network-policies/` (+ 1 file riêng cho overlay
`local`) hiện thực "default-deny ingress + whitelist" (B-25):

| File | Chọn Pod nào | Cho phép ai vào |
|---|---|---|
| `default-deny-ingress.yaml` | Mọi Pod trong `bss` | Không ai (nền tảng — các file khác mở lỗ) |
| `allow-monitoring-scrape.yaml` | `tier in (backend, edge)` | Namespace `monitoring` (Prometheus), cổng 8080 |
| `allow-public-ingress.yaml` | `tier in (edge, frontend)` | Mọi nguồn (đây là cửa vào công khai), cổng 8080 |
| `allow-gateway-to-backends.yaml` | `tier: backend` | Pod `app: api-gateway`, cổng 8080 |
| `allow-order-to-dependencies.yaml` *(GĐ9)* | `product-catalog`, `customer-service` | Pod `app: order-management`, cổng 8080 — lấy giá (B-13) + hồ sơ khách `/me` (ADR-008) |
| `overlays/local/network-policies-local.yaml` | `postgres`, `localstack` | 4 backend (Postgres), `order-management`+`billing-service` (LocalStack) |

**Chỉ khóa INGRESS, không khóa EGRESS** — quyết định có chủ đích (xem comment đầy đủ trong
`default-deny-ingress.yaml`). Khóa egress đúng cách cần liệt kê hết đích ra ngoài cluster (DNS,
AWS STS/SQS/EventBridge, RDS, GitHub Packages…) — để dành cho 1 thay đổi riêng, kỹ hơn.

## 2. Enforcement — vì sao PHẢI tự kiểm chứng, không tin `kubectl apply` thành công

`kubectl apply` một NetworkPolicy **luôn thành công** trên mọi cluster (nó chỉ là 1 object lưu
vào etcd) — **CNI mới là thứ thật sự chặn traffic**.

> ⚠️ **Cập nhật Giai đoạn 9 (2026-09-28) — điều ghi ở GĐ7 đã KHÔNG còn đúng:** GĐ7 ghi "kindnet không
> thực thi NetworkPolicy". `kindnetd` bản hiện tại của cluster `kind-bss`
> (`kindest/kindnetd:v20260820-…`) **CÓ enforce**. Hệ quả thật: từ khi áp policy của GĐ7, mọi lần đặt
> hàng trên kind đều hỏng — order-management gọi product-catalog để lấy giá (B-13) bị **"Connect timed
> out"** → circuit breaker mở → **503**. Ma trận GĐ7 dưới đây chỉ dùng **Pod giả**, không có luồng
> service-gọi-service thật nào, nên bỏ lọt. Sửa: `allow-order-to-dependencies.yaml`. Bài học: ma trận
> kiểm NetworkPolicy phải gồm **mọi luồng gọi thật giữa các service**, không chỉ "kẻ lạ bị chặn".

### Ma trận với Pod service THẬT trên `kind-bss` (Giai đoạn 9, đã chạy 2026-09-28)

Pod "kẻ lạ" phải khai `securityContext` chuẩn `restricted`, vì namespace `bss` enforce Pod Security
Standards (GĐ2). Nếu thiếu, admission từ chối tạo Pod, và mọi dòng "bị chặn" sẽ là kết quả giả (lệnh
exec lỗi chứ không phải bị chặn — đã tự dính lỗi này 1 lần).

| Kịch bản | Kỳ vọng | Kết quả thật |
|---|---|---|
| `order-management` → `product-catalog` | Đi qua | ✅ OPEN |
| `order-management` → `customer-service` | Đi qua | ✅ OPEN |
| `billing-service` → `product-catalog` (không cần) | Bị chặn | ✅ BLOCKED |
| Pod lạ → `product-catalog` / `customer-service` | Bị chặn | ✅ timeout |
| Pod lạ → `api-gateway` (cửa công khai) | Đi qua | ✅ 200 |

### Tự kiểm chứng THẬT bằng 1 cluster kind tạm có Calico (đã làm, xem PR Giai đoạn 7 việc 5)

```bash
# 1. Cluster tạm, TẮT CNI mặc định, để cài Calico thay vào
cat > /tmp/netpol-kind.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: netpol-test
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
nodes:
  - role: control-plane
EOF
kind create cluster --config /tmp/netpol-kind.yaml
kubectl --context kind-netpol-test apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml
kubectl --context kind-netpol-test -n kube-system wait --for=condition=ready pod -l k8s-app=calico-node --timeout=180s

# 2. Pod giả lập tối thiểu (không cần dựng cả 7 service thật)
kubectl --context kind-netpol-test create ns bss
kubectl --context kind-netpol-test create ns monitoring
kubectl --context kind-netpol-test -n bss run fake-billing --image=python:3.12-alpine --labels=app=billing-service,tier=backend -- python -m http.server 8080
kubectl --context kind-netpol-test -n bss expose pod fake-billing --port=8080
kubectl --context kind-netpol-test -n bss run fake-gateway --image=python:3.12-alpine --labels=app=api-gateway,tier=edge -- python -m http.server 8080
kubectl --context kind-netpol-test -n bss expose pod fake-gateway --port=8080
kubectl --context kind-netpol-test -n bss run intruder --image=curlimages/curl:8.10.1 --labels=app=intruder -- sleep 3600
kubectl --context kind-netpol-test -n monitoring run fake-prometheus --image=curlimages/curl:8.10.1 -- sleep 3600

# 3. Áp ĐÚNG 4 file thật trong repo (không phải bản chép/giả lập)
kubectl --context kind-netpol-test apply -f infrastructure/kubernetes/base/network-policies/

# 4. Ma trận kiểm tra
kubectl --context kind-netpol-test -n bss exec intruder -- curl -m3 -o/dev/null -w '%{http_code}\n' http://fake-billing:8080   # phải TIMEOUT (bị chặn)
kubectl --context kind-netpol-test -n bss exec fake-gateway -- python -c "import urllib.request as u; print(u.urlopen('http://fake-billing:8080',timeout=3).status)"  # 200
kubectl --context kind-netpol-test -n monitoring exec fake-prometheus -- curl -m3 -o/dev/null -w '%{http_code}\n' http://fake-billing.bss.svc.cluster.local:8080     # 200
kubectl --context kind-netpol-test -n bss exec intruder -- curl -m3 -o/dev/null -w '%{http_code}\n' http://fake-gateway:8080  # 200 (public ingress)

kind delete cluster --name netpol-test   # dọn ngay sau khi xong — cluster này chỉ để kiểm tra
```

**Kết quả đã tự chạy thật (Giai đoạn 7 việc 5):**

| Kịch bản | Kỳ vọng | Kết quả thật |
|---|---|---|
| `intruder` (không whitelist) → `billing:8080` | Bị chặn | ✅ timeout (exit 28) |
| `api-gateway` → `billing:8080` | Đi qua | ✅ 200 |
| `monitoring` namespace → `billing:8080` | Đi qua | ✅ 200 |
| `intruder` → `api-gateway:8080` (public) | Đi qua | ✅ 200 |

Đây chính là checkpoint Giai đoạn 7: **"Pod ngoài whitelist không gọi được billing" — ĐẠT**.

### Trên EKS thật

VPC CNI (`aws-node`) hỗ trợ NetworkPolicy từ bản `v1.14+` — bật bằng cấu hình addon
`network_policy_configuration { enabled = true }` (Terraform, module `eks` — **chưa bật**, việc
riêng, cần `terraform apply` thật nên hỏi trước theo CLAUDE.md §9). Sau khi bật, lặp lại ma trận
kiểm tra ở trên **trực tiếp trên cluster dev** (không cần Calico) bằng 3 Pod tạm tương tự.

## 3. Sự cố hay gặp sau khi bật NetworkPolicy thật

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| Prometheus Target chuyển "down" hàng loạt sau khi bật NetworkPolicy | Thiếu `allow-monitoring-scrape` hoặc nhãn `tier` sai | `kubectl -n bss get pods --show-labels`, so với `matchExpressions` trong policy |
| Pod mới thêm (chưa có trong bài) không nhận traffic dù đúng logic nghiệp vụ | Thiếu 1 luật `allow-*` cho luồng gọi MỚI | Thêm file `allow-<nguồn>-to-<đích>.yaml`, đăng ký vào `kustomization.yaml`, theo đúng mẫu 4 file hiện có |
| readiness/livenessProbe của Postgres/LocalStack (overlay local) fail sau khi bật NetworkPolicy trên CNI enforce thật | **Chưa kiểm chứng** — tùy CNI có coi traffic probe của kubelet là "Pod-to-Pod" hay không | Xem comment cảnh báo trong `overlays/local/network-policies-local.yaml`; nếu gặp, thêm `ipBlock` cho dải IP node hoặc dùng `exec` probe thay `httpGet` |
| Đổi tên Namespace `monitoring` | `namespaceSelector` dùng nhãn tự động `kubernetes.io/metadata.name` — đổi tên namespace tự đổi theo, không cần sửa policy | — |

## 4. Tự kiểm tra

1. Vì sao `kubectl apply` một NetworkPolicy sai logic vẫn "thành công" mà không cảnh báo gì?
2. Vì sao PR này không khóa egress? Rủi ro của việc "khóa nửa vời" (chỉ ingress) là gì?
3. `allow-public-ingress` chọn `tier in (edge, frontend)` — nếu thêm 1 service `tier: backend`
   mới cần public access trực tiếp (hiếm gặp, nhưng giả sử), sửa policy nào?

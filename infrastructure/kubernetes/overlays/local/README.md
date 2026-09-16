# overlays/local — chạy toàn bộ BSS Platform trên kind ($0 chi phí)

Giai đoạn 2 của `learning/20-lo-trinh-hoan-thanh.md`. Không cần AWS account, không cần domain
thật — chỉ cần Docker Desktop đang chạy.

## Quy trình đầy đủ

```bash
# 1. Cài kind + helm nếu chưa có (xem learning/nhat-ky-hoc-tap.md để biết cách tải binary trên
#    Windows nếu không dùng WSL/Linux có sẵn package manager).

# 2. Dựng cluster + ingress-nginx + metrics-server (idempotent — chạy lại vô hại)
./scripts/kind-up.sh

# 3. Build 7 image (tag "local")
make build-images   # hoặc chạy tay `docker build -t bss/<svc>:local <path>` từng cái

# 4. Nạp cả 7 image vào containerd BÊN TRONG node kind — Docker daemon của bạn và containerd của
#    kind là 2 nơi lưu image tách biệt, "docker images" thấy image không có nghĩa là Pod trong
#    kind pull được nó.
for s in customer-service product-catalog order-management billing-service api-gateway web-portal admin-console; do
  kind load docker-image bss/$s:local --name bss
done

# 5. Apply toàn bộ overlay (namespace bss được tạo tự động cùng lần apply đầu tiên)
kubectl --context kind-bss apply -k infrastructure/kubernetes/overlays/local

# 6. Theo dõi tới khi đủ 9 Pod Running/Ready (7 service + postgres-0 + localstack)
kubectl --context kind-bss -n bss get pods -w

# 7. Kiểm tra end-to-end qua Ingress thật (giống hệt scripts/e2e-local.sh nhưng qua kind)
./scripts/e2e-kind.sh

# 8. Web-portal: http://bss.localtest.me/       Admin-console: http://bss.localtest.me/admin/
#    (*.localtest.me luôn phân giải về 127.0.0.1 — không cần sửa /etc/hosts)

# Dọn dẹp hoàn toàn khi xong (xoá luôn cluster + mọi dữ liệu Postgres/LocalStack)
./scripts/kind-down.sh
```

## Khác gì so với overlays/dev|staging|prod

| | dev/staging/prod (AWS) | local (kind) |
|---|---|---|
| Database | RDS (chưa có bootstrap DB thật — B-21) | StatefulSet `postgres` trong chính namespace `bss` |
| Event bus / queue | EventBridge + SQS thật | Deployment `localstack` giả lập cùng API |
| Secret DB | Secrets Store CSI (chưa hoàn thiện — B-20) | `secretGenerator` của Kustomize (Secret thật, tạo ngay lúc `apply`) |
| Danh tính AWS của Pod | IRSA (`eks.amazonaws.com/role-arn`) | Không cần — LocalStack không kiểm tra IAM thật, dùng credential tĩnh `test/test` |
| Ingress | `ingressClassName: alb`, cần ACM + Route 53 | `ingressClassName: nginx`, host `bss.localtest.me` (không cần domain thật) |
| Thay đổi state khi restart Pod | RDS/EventBridge sống độc lập với cluster | `postgres-0` có PVC riêng (sống qua Pod restart); `localstack` **không** có PVC bền (Pod restart → toàn bộ bus/queue/secret bị tạo lại từ đầu bởi init script — chấp nhận được vì mục đích là học K8s, không phải để dữ liệu lâu dài) |

## Vì sao 4 backend restart vài lần khi mới `apply` lần đầu

`kubectl -n bss get pods` ngay sau khi apply sẽ thấy `customer-service`, `product-catalog`,
`order-management`, `billing-service` vào `CrashLoopBackOff` 3-5 lần rồi mới ổn định — đây
**không phải lỗi cấu hình**, mà là hệ quả tự nhiên của việc apply toàn bộ overlay cùng một lúc:
4 Pod này chạy Flyway lúc khởi động, cần kết nối được `postgres.bss.svc.cluster.local`, nhưng DNS
của một headless Service chỉ trả về pod-IP khi Pod đó đã **Ready** — trong vài chục giây đầu,
`postgres-0` còn đang pull image + chạy init script, nên 4 service kia gặp
`UnknownHostException`/`connection refused`, bị kubelet restart, rồi thử lại — và tự thành công
ngay khi `postgres-0` sẵn sàng (Kubernetes's restart policy đã "chờ hộ" mà không cần viết thêm
`initContainer` chờ DB, dù thêm initContainer đó vẫn là cách làm sạch hơn cho production — xem
`learning/13` bảng "Triệu chứng" mục `CrashLoopBackOff`).

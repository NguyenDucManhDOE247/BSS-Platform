# Runbook: service down / hết replica (`BssServiceDown`, `BssDeploymentUnavailable`, `BssDeploymentDegraded`)

> Alert nằm ở `platform/monitoring/alerts/bss-alerts.yaml`. Mục tiêu: trong **≤ 5 phút** biết
> service nào chết, vì sao, và đưa nó sống lại (hoặc leo thang).
> Trước tiên đọc `## 0` để biết đang cầm alert nào — 3 alert này nhìn giống nhau nhưng khác nguyên nhân.

## 0. Ba alert, ba câu hỏi khác nhau

| Alert | Nghĩa | Mức | Ai phát hiện |
|---|---|---|---|
| `BssDeploymentUnavailable` | Deployment có **0 replica sẵn sàng** ≥ 1 phút | critical | kube-state-metrics (đọc từ API server) |
| `BssServiceDown` | Prometheus **scrape thất bại** (`up == 0`) ≥ 2 phút | critical | chính Prometheus |
| `BssDeploymentDegraded` | Còn chạy nhưng **thiếu replica** so với mong muốn ≥ 10 phút | warning | kube-state-metrics |

Vì sao cần cả hai alert critical? Khi bạn `kubectl scale --replicas=0` (hoặc xóa) một service,
target biến mất khỏi Prometheus → series `up` **không còn tồn tại** → `up == 0` không có gì để so
sánh → `BssServiceDown` **im lặng**. Chỉ `BssDeploymentUnavailable` (dựa trên kube-state-metrics)
bắt được. Ngược lại `BssServiceDown` bắt được ca "Pod vẫn Ready nhưng `/actuator/prometheus` hỏng".
Cả hai đều được test bằng `promtool` (`./scripts/test-alert-rules.sh`).

## 1. Xác nhận trong 30 giây

```bash
kubectl -n bss get deploy,pods -o wide                      # cột READY / STATUS / RESTARTS
kubectl -n bss get deploy <service> -o jsonpath='{.spec.replicas} {.status.availableReplicas}{"\n"}'
```

- `spec.replicas = 0` → ai đó (hoặc script/HPA) đã scale về 0. Xem `kubectl -n bss get hpa`,
  nhật ký CD (`gh run list --workflow cd-dev.yml`), rồi **scale lại**: `kubectl -n bss scale deploy/<service> --replicas=<số cũ>`
  (số cũ nằm trong `infrastructure/kubernetes/overlays/<env>/kustomization.yaml`).
- `spec.replicas > 0` nhưng `availableReplicas` rỗng/0 → đi tiếp mục 2.

## 2. Pod không lên — đọc `STATUS`

| STATUS | Ý nghĩa | Xem gì | Xử lý |
|---|---|---|---|
| `ImagePullBackOff` / `ErrImagePull` | Không kéo được image | `kubectl -n bss describe pod <pod>` → Events | Tag không tồn tại trong ECR? (CD dev: xem `deploy-state`); ECR/NAT/VPC endpoint hỏng? Rollback: chạy lại `cd-dev` từ commit tốt. |
| `CrashLoopBackOff` | Container chạy rồi chết | `kubectl -n bss logs <pod> --previous` | Sang runbook `bss-pod-crash-looping.md`. |
| `Pending` | Scheduler chưa xếp được | `kubectl -n bss describe pod <pod>` → dòng `FailedScheduling` | "Insufficient cpu/memory" = **node hết tài nguyên** (sự cố thật ở buổi staging đầu tiên): thêm node / hạ `requests` / xóa Pod thừa. Xem `docs/runbooks/cd-staging-prod-demo.md` phần quota vCPU. |
| `CreateContainerConfigError` | Thiếu Secret/ConfigMap tham chiếu | `describe pod` → `secret "…" not found` | Secrets Store CSI chưa sync? `kubectl -n bss get secretproviderclass`; chạy lại `db-bootstrap`; kiểm tra IRSA role. |
| `Running` nhưng `0/1 READY` | Readiness probe fail | `kubectl -n bss describe pod` → `Readiness probe failed`; log app | DB không kết nối được (Secret/SG/RDS down?), hoặc app chưa khởi động xong. |
| `NetworkPolicy` chặn (sau GĐ7) | Probe/kết nối bị drop âm thầm | `kubectl -n bss get netpol`; thử `kubectl -n bss exec` gọi cổng đích | Xem `docs/runbooks/network-policy.md`. |

## 3. Thiếu replica (`BssDeploymentDegraded`)

Thường không khẩn cấp (service vẫn phục vụ) nhưng **mất dự phòng**: một Pod nữa chết là thành sự cố.

```bash
kubectl -n bss get pods -l app=<service> -o wide
kubectl -n bss describe pod <pod-Pending> | sed -n '/Events/,$p'
kubectl describe nodes | grep -A6 "Allocated resources"     # node còn bao nhiêu CPU/memory request?
```

Nguyên nhân hay gặp: (1) node hết CPU *request* (dù tải thật thấp — scheduler tính theo `requests`);
(2) `topologySpreadConstraints` + thiếu AZ; (3) đang rolling update dài; (4) Pod bị evict do node pressure.

## 4. `BssServiceDown` mà Pod vẫn `Ready`

Prometheus không scrape được nhưng Kubernetes coi Pod khỏe → thường do **NetworkPolicy** (thiếu rule cho
namespace `monitoring`) hoặc `/actuator/prometheus` bị chặn bởi bảo mật. Kiểm tra:

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
# UI → Status → Targets → job <service> → cột "Error" cho biết lý do (connection refused / timeout / 401 / 403)
```

## 5. Leo thang

Quá 15 phút chưa hồi phục service critical, hoặc ≥ 2 service cùng chết (nghi hạ tầng: node/AZ/RDS/NAT)
→ báo người phụ trách hạ tầng, đính kèm: output `kubectl -n bss get pods -o wide`, `describe` của Pod lỗi,
thời điểm alert bắt đầu Firing.

## 6. Tự kiểm tra sau xử lý

- `kubectl -n bss get deploy` → tất cả `READY` = số replica mong muốn.
- Alert chuyển `Resolved` trong Alertmanager (chờ tối đa vài phút).
- `./scripts/smoke.sh` (nếu có ALB) → PASS.

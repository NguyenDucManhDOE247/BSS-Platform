# Runbook: Pod restart liên tục (`BssPodCrashLooping`)

> Alert: `rate(kube_pod_container_status_restarts_total{namespace="bss"}[15m]) > 0` suốt 10 phút —
> container chết rồi bị kubelet khởi động lại lặp đi lặp lại (`CrashLoopBackOff` là trạng thái kubelet
> *chờ lâu dần* giữa các lần thử: 10s, 20s, 40s… tối đa 5 phút).

## 1. Lấy bằng chứng TRƯỚC khi làm bất cứ gì khác

```bash
kubectl -n bss get pods                                   # cột RESTARTS
kubectl -n bss describe pod <pod>                         # xem "Last State", "Exit Code", "Reason", Events
kubectl -n bss logs <pod> --previous --tail=200           # log của LẦN CHẠY TRƯỚC (lần hiện tại có thể trống)
```

⚠️ Đừng `kubectl delete pod` vội — Pod mới có thể chết y hệt, còn bằng chứng (`--previous`) mất.

## 2. Đọc `Exit Code` / `Reason`

| Dấu hiệu | Nguyên nhân | Việc cần làm |
|---|---|---|
| `Reason: OOMKilled`, exit **137** | Vượt `limits.memory` (kernel giết) | Xem `bss-jvm-heap-high.md`. Kiểm tra `limits.memory` vs `-XX:MaxRAMPercentage`. **Không** chỉ tăng limit — tìm xem heap có rò rỉ không. |
| exit **1** + stack trace lúc khởi động | Lỗi ứng dụng: thiếu biến môi trường, không kết nối được DB, Flyway lỗi | Đọc log `--previous`. Ví dụ thật: `Schema-validation: missing column` (migration/code lệch), `Connection refused` (RDS/SG/Secret sai). |
| exit **143** rồi chết lặp | Bị SIGTERM: liveness probe fail liên tục → kubelet giết | `describe pod` → `Liveness probe failed`. Startup chậm hơn `startupProbe` cho phép? Tăng `failureThreshold` (hiện 30×5s = 150s). |
| `Readiness/Liveness probe failed` trong Events | Probe sai đường dẫn/cổng, hoặc **NetworkPolicy** chặn kubelet | `curl` thử trong Pod; xem `docs/runbooks/network-policy.md`. |
| `CreateContainerConfigError` | Secret/ConfigMap thiếu (chưa có Pod chạy lần nào) | Xem `bss-service-down.md` mục 2. |
| Lỗi `read-only file system` | `readOnlyRootFilesystem: true` + app cố ghi ra ngoài `/tmp` | Thêm `emptyDir` mount đúng thư mục app cần ghi (xem `volumeMounts` trong Deployment). |
| Chết ngay khi có traffic | Bug logic/`NullPointerException` ở endpoint cụ thể | Log lúc trước khi chết; tái hiện bằng test; rollback bản deploy gần nhất. |

## 3. Nếu vừa deploy xong

CrashLoop ngay sau deploy = bản mới hỏng. Rolling update có `maxUnavailable: 0` nên Pod cũ vẫn phục vụ
(người dùng chưa bị ảnh hưởng) — CD dev sẽ tự rollback khi `rollout status` timeout (ADR-005). Nếu chưa tự
rollback: chạy lại `cd-dev` từ commit tốt cuối (`gh workflow run cd-dev.yml --ref <sha-tốt>`).

## 4. Debug sâu (khi log không đủ)

```bash
# Pod debug tạm: cùng image + env nhưng KHÔNG chạy app, để exec vào xem (nhớ securityContext 'restricted' —
# namespace bss bật Pod Security, thiếu là bị Forbidden).
kubectl -n bss debug pod/<pod> -it --image=busybox:1.36 --target=app
```

## 5. Sau sự cố

Test tái hiện (fail trước, pass sau) theo quy ước PROJECT.md §9 và ghi vào nhật ký/postmortem.

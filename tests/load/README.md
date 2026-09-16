# tests/load — k6

Checkpoint cuối của Giai đoạn 2 (`learning/20` dòng 123): "k6 ở 50 VU → HPA tăng pod; dừng tải →
giảm sau ~5 phút".

## Chạy

```bash
# Cluster kind đã dựng (scripts/kind-up.sh) + overlays/local đã apply + metrics-server sẵn sàng.
k6 run tests/load/plans-and-order.js
```

Mở 1 terminal khác, quan sát trong lúc k6 chạy:

```bash
kubectl --context kind-bss -n bss get hpa -w
kubectl --context kind-bss -n bss get pods -w
```

## Đọc kết quả thế nào

- `REPLICAS` (cột trong `kubectl get hpa`) tăng dần khi `TARGETS` (vd. `142%/70%`) vượt ngưỡng —
  service chịu tải nặng nhất thường là `order-management` (ghi DB + gọi product-catalog + ghi
  outbox) và `api-gateway` (mọi request đều qua đây).
- Sau khi k6 dừng (hết 3 stage, ~5 phút), **đừng tắt terminal `get hpa -w` ngay** — HPA cần thêm
  tới 5 phút nữa mới hạ (`behavior.scaleDown.stabilizationWindowSeconds: 300` trong mọi
  `hpa.yaml`, cố ý chống dao động) — đây là hành vi đúng, không phải HPA bị treo.
- `k6` tự in bảng tổng kết cuối (p95 `http_req_duration`, tỉ lệ `checks` pass) — dùng số này để
  tự trả lời câu hỏi capacity-planning của `learning/13` mục 4: "ở 50 VU trên 1 node kind, hệ
  thống có bắt đầu chậm đi không?".

## Kết quả 1 lần chạy thật (cluster kind 1 node, `bss-control-plane`)

```
checks_succeeded...: 100.00% 21073 out of 21073   http_req_failed: 0.00%
http_req_duration..: avg=55.2ms p(90)=116.89ms p(95)=274.38ms max=1.68s
```

`kubectl -n bss get hpa` (cột REPLICAS) theo thời gian thực:

| Thời điểm | api-gateway | order-management | product-catalog | Ghi chú |
|---|---|---|---|---|
| Trước tải | 1 | 1 | 1 | baseline |
| Ngay khi hết ramp (50 VU giữ ổn định) | **12** (kịch trần `maxReplicas: 12`) | **8** | **8** | scale-up nhanh, trong ~2 phút |
| +0 phút (k6 vừa dừng) | 12 | 8 | 8 | CPU đã tụt (2-20%) nhưng `stabilizationWindowSeconds: 300` giữ nguyên |
| +5 phút | 4 | 8 | 8 | bắt đầu giảm đúng thời điểm 5 phút |
| +6 phút | 2 | 7 | 5 | tiếp tục giảm dần (K8s rate-limit số pod hạ mỗi chu kỳ, không hạ hết 1 lần) |
| +10 phút | 1 | 5 | 1 | gần hết về `minReplicas: 1` |

Đúng khớp checkpoint `learning/20`: **tăng khi có tải, giữ nguyên trong cửa sổ ổn định 5 phút sau
khi tải dừng, rồi giảm dần** — không phải giảm ngay lập tức (đó là chủ đích của
`stabilizationWindowSeconds`, chống hiện tượng "dao động" scale lên/xuống liên tục).
`api-gateway` chạm `maxReplicas: 12` (giới hạn cứng) trước cả `order-management`/`product-catalog`
— hợp lý vì **mọi** request đều đi qua gateway trong khi 2 service kia chỉ nhận phần việc riêng.

## Vì sao dùng k6 (không phải JMeter/Locust/wrk)

- Kịch bản viết bằng JavaScript (`k6`), không phải file cấu hình XML (JMeter) — dễ đọc và commit
  vào git như code thật.
- Có sẵn `stages` (ramp lên/giữ/xuống) và `thresholds` khai báo ngay trong script, không cần
  thêm plugin.
- Binary tĩnh, không cần JVM (khác JMeter/Gatling) — chạy nhẹ ngay cạnh cluster kind.

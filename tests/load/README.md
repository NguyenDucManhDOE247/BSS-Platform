# tests/load — k6

Checkpoint cuối của Giai đoạn 2 (`learning/20` dòng 123): "k6 ở 50 VU → HPA tăng pod; dừng tải →
giảm sau ~5 phút".

## Chạy

```bash
# Cluster kind đã dựng (scripts/kind-up.sh) + overlays/local đã apply + metrics-server sẵn sàng.
# Auth luôn bật (ADR-008): script tạo user Keycloak thật trong setup() nên cần mật khẩu admin master realm.
KC_ADMIN_PASSWORD=$(kubectl --context kind-bss -n bss get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)
k6 run -e KC_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD" tests/load/plans-and-order.js
```

Mỗi VU là một khách **đã được admin duyệt**, đặt hàng bằng token của chính mình. `setup()` đăng nhập bằng
mật khẩu đúng 1 lần/khách, sau đó VU chỉ gia hạn bằng `refresh_token`. Lý do: password grant bắt Keycloak băm
mật khẩu, nên 50 VU cùng đăng nhập sẽ làm Keycloak 1 CPU trên kind nghẽn (đo thật, xem bảng dưới).

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

## Kết quả có auth (2026-10-01, kind 1 node, trần HPA local = 2)

```
checks_succeeded...: 100.00% 20922 out of 20922   http_req_failed: 0.00% (20934 request)
http_req_duration..: avg=61.61ms p(90)=145.17ms p(95)=287.45ms max=2.41s
✓ token refresh: 200   ✓ create order: 201   (10411 đơn hàng, mỗi đơn qua đủ JWT + /customer/me + giá catalog)
```

RAM máy ảo WSL lấy mẫu mỗi 30 s: 5,3 GB lúc nghỉ → **ổn định ~7,6 GB** ở 50 VU (còn trống ~8,2 GB); HPA của
api-gateway, order-management, product-catalog, customer-service lên 2 trong ~2 phút đầu.

Ba lần thử trước đó, mỗi lần lộ ra một lỗi thật:

| Lần chạy | Kết quả | Nguyên nhân → cách sửa |
|---|---|---|
| Bản trước GĐ9 (không token) | "xanh" | Từ GĐ9 mọi lệnh đặt hàng là **401** nhưng script không có ngưỡng cho nó → thêm `checks{kind:order}` và `checks{kind:login}` > 99% |
| Mỗi VU tự đăng nhập bằng mật khẩu | 97,96% đơn thành công, 5/55 lần đăng nhập timeout 60 s | Keycloak (1 CPU) nghẽn vì băm mật khẩu → `setup()` đăng nhập 1 lần, VU dùng `refresh_token` |
| Trần HPA như base (tổng 46 Pod JVM) | **Cả máy ảo WSL hết RAM**, Docker Engine trả 500 | Pod JVM xin 512Mi nhưng limit 1Gi, nên scheduler xếp quá sức 1 node → overlay local đặt `maxReplicas: 2` (xem comment trong `overlays/local/kustomization.yaml`) |

> Bài học về **overcommit**: scheduler chỉ cộng `requests`, còn thực tế Pod dùng tới `limits`. Trên EKS nhiều
> node thì Karpenter/node group bù được, nhưng trên 1 node, tổng `limits` ở trần HPA phải vừa RAM node. Nếu không,
> thứ chết sẽ là cả node chứ không chỉ một Pod bị OOMKilled.

## Kết quả bản cũ — trước GĐ9, không auth (trần HPA base: api-gateway 12)

Giữ lại để so sánh. Lưu ý: hồi đó máy chưa chạy Keycloak, và đường đặt hàng chưa đi qua kiểm tra JWT.

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

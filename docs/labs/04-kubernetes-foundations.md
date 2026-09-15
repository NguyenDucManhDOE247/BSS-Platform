# Lab 04 — Kubernetes Foundations (probes, rolling update/rollback, 5 bug debug)

> Thực hiện trực tiếp trên cluster kind "bss" (Giai đoạn 2) — mọi lệnh, log, sự cố dưới đây là
> **thật**, chạy trên cụm đang sống với 7 service + Postgres + LocalStack, không phải mô tả lý
> thuyết. Theo đúng `course/04-kubernetes-foundations/README.md` Lab 4.4–4.6. Mọi thay đổi đều
> chỉ áp bằng `kubectl patch`/`set image`/`rollout` tạm thời trên cluster — **không commit** vào
> repo, khôi phục nguyên trạng ngay sau khi quan sát xong.

## Lab 4.4 — Probe: thiếu startupProbe → CrashLoopBackOff

**Thao tác:** patch `customer-service` bỏ hẳn `startupProbe`, đổi `livenessProbe` thành
`initialDelaySeconds: 1, periodSeconds: 2, failureThreshold: 1` (gần như không cho JVM thời gian
khởi động).

```bash
kubectl -n bss patch deployment customer-service --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe",
   "value":{"httpGet":{"path":"/actuator/health","port":8080},
            "initialDelaySeconds":1,"periodSeconds":2,"failureThreshold":1}},
  {"op":"remove","path":"/spec/template/spec/containers/0/startupProbe"}
]'
```

**Quan sát thật** (~90 giây sau):

```
NAME                                READY   STATUS             RESTARTS
customer-service-6666cffddb-kqfcl   0/1     CrashLoopBackOff   4 (20s ago)
customer-service-dfd7f8cf7-4pxtp    1/1     Running            0            ← Pod cũ vẫn sống (maxUnavailable: 0)
```

**Vì sao:** JVM Spring Boot cần vài giây thật sự để khởi động (nạp Flyway, mở connection pool...)
trước khi `/actuator/health` trả `200`. `failureThreshold: 1` + `periodSeconds: 2` nghĩa là kubelet
chỉ cho đúng 1 lần thử trong 2 giây đầu — chắc chắn fail — rồi **restart container** (đúng hành vi
của `livenessProbe`: fail → restart, không phải rút khỏi Service như `readinessProbe`). App không
bao giờ có cơ hội khởi động xong trước khi bị giết lần nữa → lặp vô hạn.

**Khôi phục:** trả lại `startupProbe` (30 lần thử × 5s = 150s cho JVM khởi động) + `livenessProbe`
`periodSeconds: 10` không `initialDelaySeconds` ngắn — xác nhận Pod về `1/1 Running` bình thường.

## Lab 4.5 — Rolling update + rollback

**Thao tác:** `kubectl set image` sang 1 tag không tồn tại (giả lập "release v2 lỗi") — kết hợp
luôn với **Bug #4** của Lab 4.6 (ImagePullBackOff), vì đây chính là cách một rollout tệ thường
xảy ra thật (tag sai/chưa build xong đã deploy).

```bash
kubectl -n bss set image deployment/customer-service app=bss/customer-service:v2-broken
```

**Quan sát thật:**

```
NAME                                READY   STATUS         RESTARTS
customer-service-5d7fd7ff74-b9hcp   0/1     ErrImagePull   0
customer-service-dfd7f8cf7-4pxtp    1/1     Running        0        ← Pod cũ VẪN phục vụ traffic
```

Event thật: `Failed to pull image "bss/customer-service:v2-broken": ... pull access denied,
repository does not exist`. `kubectl rollout status` treo ở "1 old replicas are pending
termination" — **không bao giờ tự xong** vì `maxUnavailable: 0` không cho phép giảm dưới số
replicas hiện có trong khi Pod mới chưa `Ready`. Đây chính xác là giá trị của
`maxUnavailable: 0`: rollout tệ **không hề gây downtime** — traffic vẫn đi vào Pod cũ nguyên vẹn.

**Rollback:**

```bash
kubectl -n bss rollout undo deployment/customer-service
# deployment.apps/customer-service rolled back
# deployment "customer-service" successfully rolled out   (gần như tức thì — Pod tốt chưa từng bị xoá)
```

## Lab 4.6 — 5 bug có chủ đích

### Bug 1 — Pod `Pending` (Insufficient memory)

```bash
kubectl -n bss patch deployment customer-service --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"20Gi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"20Gi"}
]'
```

`kubectl describe pod` → Event thật:
`0/1 nodes are available: 1 Insufficient memory. preemption: 0/1 nodes are available: 1
Preemption is not helpful for scheduling.` — node kind chỉ có vài GB, scheduler từ chối đặt Pod
xin 20Gi ngay từ đầu (không hề tạo container, không giống CrashLoopBackOff).

⚠️ Phát hiện phụ: đặt `requests` lớn hơn `limits` (thử `requests: 100Gi` khi `limits` vẫn `1Gi`)
bị API server **từ chối thẳng lúc apply**, không cần chờ scheduler:
`Invalid value: "100Gi": must be less than or equal to memory limit of 1Gi` — một lớp bảo vệ có
sẵn của Kubernetes, không phải lỗi cấu hình của dự án.

### Bug 2 — `CrashLoopBackOff` (sai biến môi trường / mật khẩu DB)

```bash
kubectl -n bss patch secret customer-db-credentials-<hash> --type=json -p \
  '[{"op":"replace","path":"/data/password","value":"'"$(echo -n wrongpassword | base64)"'"}]'
kubectl -n bss rollout restart deployment/customer-service
```

Log thật: `FlywaySqlException: Unable to obtain connection from database` →
`PSQLException: FATAL: password authentication failed for user "bss"`. Khác hẳn Lab 4.4: ở đây
container **thực sự khởi động và cố kết nối DB thật**, không phải do probe cấu hình sai — cùng
triệu chứng bên ngoài (`CrashLoopBackOff`) nhưng nguyên nhân gốc khác nhau, đúng bài học "đọc log
trước khi đoán nguyên nhân" (`learning/13` mục 7 bảng triệu chứng).

### Bug 3 — Service không route (port mismatch)

```bash
kubectl -n bss patch service customer-service --type=json -p \
  '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9999}]'
```

`kubectl get endpoints customer-service` → `10.244.0.84:9999` (đúng IP Pod, sai cổng — Service
**không hề biết** cổng đó có ai lắng nghe hay không, nó chỉ ghép theo cấu hình). Gọi qua gateway:
`http_code=500` (không phải 502/504 "gateway lỗi" gọn gàng hơn — Spring Cloud Gateway trả 500
chung chung khi kết nối downstream bị từ chối, một điểm có thể cải thiện UX lỗi sau này).

### Bug 4 — `ImagePullBackOff` (sai tag image)

Đã minh hoạ ở Lab 4.5 (`bss/customer-service:v2-broken`) — 1 tình huống, 2 bài học (rollout an
toàn + cách chẩn đoán ImagePullBackOff) cùng lúc.

### Bug 5 — Đổi ConfigMap không tự động reload

```bash
kubectl -n bss exec deploy/customer-service -- printenv LOGGING_LEVEL_ROOT   # DEBUG
kubectl -n bss patch configmap customer-service-config-<hash> --type merge \
  -p '{"data":{"LOGGING_LEVEL_ROOT":"TRACE"}}'
kubectl -n bss exec deploy/customer-service -- printenv LOGGING_LEVEL_ROOT   # VẪN LÀ DEBUG
kubectl -n bss rollout restart deployment/customer-service
kubectl -n bss exec deploy/customer-service -- printenv LOGGING_LEVEL_ROOT   # nay mới TRACE
```

**Đối chiếu quan trọng:** đây là patch **trực tiếp vào ConfigMap đã tồn tại trên cluster** (bỏ
qua Kustomize) — mô phỏng đúng tình huống "ai đó `kubectl edit` thẳng trên cluster". Trong quy
trình bình thường của repo này, sửa `configMapGenerator` trong overlay rồi `kubectl apply -k` lại
**tự động sinh tên ConfigMap mới** (hash đổi) → Deployment tự động rolling restart, không cần
nhớ gõ `rollout restart` tay — đúng lợi ích của Kustomize đã ghi trong `learning/13` mục 3.2.
Bug 5 chỉ xảy ra khi ai đó sửa "tắt" qua `kubectl patch`/`edit` như demo ở trên.

## Phát hiện phụ ngoài kế hoạch (đáng ghi lại)

Trong lúc chạy lại `./scripts/e2e-kind.sh` để xác nhận cluster lành sau toàn bộ lab, script
**FAIL thật**: `no invoice appeared within 90s`. Điều tra:

```bash
kubectl -n bss exec postgres-0 -- psql -U bss -d orders  -t -c "SELECT count(*) FROM product_order;"  # 10535
kubectl -n bss exec postgres-0 -- psql -U bss -d billing -t -c "SELECT count(*) FROM invoice;"          # 3012, đang tăng dần
```

**Không phải bug** — hệ quả của chính `tests/load/plans-and-order.js` (PR #55) vừa tạo **10.535
đơn hàng** trong 5 phút. Hàng đợi SQS (LocalStack) xử lý tuần tự, tốc độ tiêu thụ của
`billing-service` **chậm hơn nhiều** tốc độ k6 tạo đơn — invoice của lần `e2e-kind.sh` mới nhất
bị xếp hàng phía sau hàng nghìn message cũ, không kịp trong 90 giây timeout của script. Xác nhận
bằng cách đếm lại sau vài chục giây thấy con số invoice **tăng dần** (3012 → 3042) — hệ thống vẫn
xử lý đúng, chỉ chậm vì tồn đọng do chính bài test tải trước đó gây ra.

🧠 Bài học thật: **k6 tạo dữ liệu thật, tồn tại thật sau khi test xong** — không giống load test
"giả lập" chỉ đo latency. Muốn `e2e-kind.sh` chạy nhanh ngay sau `k6`, cần: (a) đợi hàng đợi rút
hết trước khi test tiếp, hoặc (b) tăng tốc độ tiêu thụ (`billing-service` hiện poll theo batch nhỏ
mỗi vài giây — hợp với tải bình thường, không phải để rút cạn backlog lớn nhanh). Đây chính là câu
hỏi capacity-planning thật mà `learning/13` mục 4 đặt ra, áp dụng cho **hàng đợi** thay vì CPU/pod.

## Phát hiện phụ thứ 2 (đã sửa thật trong PR #55, không chỉ ghi chú)

Khi HPA scale `order-management`/`product-catalog` lên 8 pod mỗi loại lúc chạy k6, 1 Pod
`order-management` mới rơi vào `CrashLoopBackOff` thật:

```
FlywaySqlException: Unable to obtain connection from database
PSQLException: FATAL: sorry, too many clients already
```

Nguyên nhân: Postgres mặc định `max_connections: 100`; mỗi Pod mở 1 HikariCP pool (mặc định 10
connection) — 8 pod × 10 × 2 service (order + product) đã vượt xa 100. Đã sửa bằng cách nâng
`max_connections: 200` cho Postgres StatefulSet (`overlays/local/postgres/statefulset.yaml`,
commit trong PR #55) — coi đây là "ngân sách connection" tương tự "ngân sách pod" của
`learning/13` mục 4, chỉ khác đơn vị đo.

## Checklist đã đạt (đúng `course/04` mục Checkpoint)

- [x] Hiểu khác nhau 3 probe qua quan sát thật (không chỉ đọc bảng lý thuyết).
- [x] Rolling update giữ zero-downtime nhờ `maxUnavailable: 0`; rollback gần như tức thì.
- [x] Debug đủ 5/5 bug bằng `describe`/`logs`/`get events`/`get endpoints` thật, có log nguyên
      văn dán lại ở trên (không phải suy đoán).
- [x] 2 phát hiện phụ ngoài kế hoạch — 1 đã sửa thật (connection pool), 1 ghi lại làm bài học
      (queue backlog do chính k6 gây ra).

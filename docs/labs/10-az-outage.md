# Lab 10 — Mất 1 Availability Zone trên prod (2026-10-02)

> Mục "Phase 9 — fail 1 AZ → cluster vẫn serve" trong kế hoạch scaffold (CLAUDE.md §8) — mục duy nhất của kế hoạch
> cũ chưa từng làm. Chạy thật trên **prod** (3 AZ, 4 × t3.large, RDS db.t3.medium Multi-AZ, 3 replica/service,
> Keycloak 2 replica), release `v2.2.0`, qua `https://bssplatform.dpdns.org` với cert thật.
> Script: [`scripts/chaos-az-outage.sh`](../../scripts/chaos-az-outage.sh). Số liệu thô (gitignored):
> `results/az-outage-prod-run*/`.

## 0. Thí nghiệm làm gì — và vì sao làm như vậy

Mô phỏng kịch bản **"AZ Availability: Power Interruption"** của AWS Fault Injection Service bằng AWS CLI thuần:

| Bước | Cách làm | Mô phỏng điều gì |
|---|---|---|
| 1 | Gắn một **NACL deny-all** vào subnet **private** của AZ bị chọn (NACL mới tạo không có rule allow nào) | Node + Pod ở AZ đó mất liên lạc hoàn toàn: với control plane, với Pod khác, với RDS. Gói tin **mất hút** (không có RST) — đúng cảm giác "AZ mất điện" |
| 2 | Nếu RDS primary ở đúng AZ đó: `aws rds reboot-db-instance --force-failover` | AWS tự failover khi mất AZ thật; với NACL thì RDS không "thấy" gì nên phải ép |
| 3 | 2 đầu dò mỗi giây qua `https://<host>` (`curl --connect-to`, kiểm cert thật): API catalog (ALB → gateway → product-catalog → RDS) và OIDC discovery (ALB → Keycloak) | Người dùng thật thấy gì |
| 4 | Sau `DURATION` giây trả NACL gốc, theo dõi thêm `RECOVERY` giây | Hồi phục |

Chọn AZ **đang chứa RDS primary** = trường hợp tệ nhất: mất cùng lúc 1/3 compute **và** DB phải failover.

**Giới hạn có chủ đích:** không chặn subnet **public**. Mất AZ thật còn làm mất node ALB và **NAT Gateway** ở AZ đó.
Module `vpc` chỉ có **1 NAT** (ở AZ đầu tiên, `ap-southeast-1a`): mất đúng AZ đó = mọi Pod mất đường ra Internet
(SQS, EventBridge, STS, ECR) → luồng order → hóa đơn dừng. Đó là **điểm chết đơn (SPOF) đã biết**, ghi ở mục 4.

## 1. Lần chạy 1 — `v2.2.0` (Keycloak 26.7.5)

```bash
OUT_DIR=results/az-outage-prod-run1 ./scripts/chaos-az-outage.sh prod ap-southeast-1b   # DURATION=420 RECOVERY=240
```

Trước thí nghiệm: `e2e-flow.sh prod` **PASS**. Node: 1a ×1, 1b ×1, 1c ×2. Pod `bss`: 6 / 7 / 9 theo AZ. RDS primary
`1b`, standby `1a`. Cô lập `1b` (1 node, 7 Pod) lúc t = 0, ép failover RDS 1 s sau.

| Đo | Kết quả |
|---|---|
| **API catalog** | **4 / 449 lỗi (0,89 %)** — 4 lần timeout 5 s (mã `000`) ở t = 2, 8, 14, 21 s, rồi **0 lỗi** suốt phần còn lại. p95 độ trễ request thành công 0,32 s |
| **OIDC (Keycloak)** | **371 / 448 lỗi (82,8 %)** — `503` liên tục từ **t = 52 s tới hết thí nghiệm (t = 662 s)**, tức vẫn hỏng **4 phút sau khi mạng đã trả lại** |
| RDS | `rebooting` t ≈ 7 → `available` t ≈ 75 s; lỗi API dừng ở t = 21 s nên thời gian DB thật sự gián đoạn với app ngắn hơn trạng thái RDS báo. (Trường `AvailabilityZone` của `describe-db-instances` báo AZ mới **trễ ~8 phút**, t ≈ 518 s — đừng dùng nó để đo failover) |
| Node `1b` | `NotReady` từ t ≈ 61 s (≈ `node-monitor-grace-period`), `Ready` lại t ≈ 437 s (mạng trả ở t = 423) |
| Pod | Pod trên node `1b` bị đuổi sau ~300 s (`tolerationSeconds` mặc định cho node unreachable), Pod Ready thấp nhất 12; **0 Pod Pending** — 3 node còn lại đủ chỗ cho phần bị đuổi |

**Kết luận phần ứng dụng:** 5 service Spring sống sót gần như hoàn hảo: lỗi chỉ trong ~20 s đầu (khớp với lúc ALB
health check còn gửi request tới target ở `1b`), mỗi service còn ≥ 2 replica ở 2 AZ khác (topology spread theo AZ +
3 replica) — đúng mục đích của thiết kế. (Đầu dò chỉ đi qua product-catalog; luồng ghi đầy đủ được kiểm bằng
`e2e-flow.sh` sau thí nghiệm — mục 3.)

### 1.1 Lỗi thật: Keycloak mất cluster sau RDS failover và KHÔNG tự hồi phục

Log (`results/az-outage-prod-run1/keycloak-*.log`) cho thấy **2 pha**, dù **không Pod Keycloak nào nằm ở `1b`**:

| Pha | Bằng chứng | Nguyên nhân |
|---|---|---|
| A — trong lúc mất AZ | `RejectedExecutionException: No executor queue space remaining`, pool `Acquisition timeout`, `failed writing to DB` | Kết nối DB cũ tới primary ở `1b` treo (gói tin mất hút, không RST → chờ timeout TCP của kernel ~15 phút). Mọi worker thread kẹt chờ DB → health check bị từ chối → `/health/ready` DOWN |
| B — sau khi mạng đã trả | `database connections … UP` nhưng `"Keycloak cluster health check","status":"DOWN"` — `Unable to check the cluster health because no coordinator has been found`, JGroups `sender … not found` | Khi ghi/đọc bảng `JGROUPS_PING` thất bại, 2 Pod rời view của nhau và **không ghép lại**. Từ Keycloak 26.4, readiness có kiểm "chỉ 1 coordinator trong `jgroups_ping`" → cả 2 Pod DOWN vô thời hạn |

Đây đúng là [keycloak/keycloak#51797](https://github.com/keycloak/keycloak/issues/51797) ("jdbc-ping failed to create a
cluster after the database restore", chỉ hồi phục khi restart tay), sửa bằng
[#51916](https://github.com/keycloak/keycloak/pull/51916) ("Set bounded network timeout on JDBC_PING2 connections") —
**chỉ có từ 26.8.0** (ra 2026-10-01; 26.7.5 không có).

**Khôi phục tạm:** `kubectl -n bss rollout restart deploy/keycloak` → OIDC 200 sau **89 s**; rồi `e2e-flow.sh prod`
**PASS** (đăng ký → duyệt → mua → hóa đơn qua SQS → admin thấy đúng) trên RDS đã chuyển sang `1a`. Không có người can thiệp,
đăng nhập sẽ sập vô thời hạn sau mỗi lần DB failover — kể cả failover do AWS bảo trì, không cần mất AZ.

## 2. Sửa

| Thay đổi | Nhắm vào | File |
|---|---|---|
| Keycloak **26.7.5 → 26.8.0** (bản có #51916). Trivy image 26.8.0: **0 HIGH/CRITICAL** → xóa nốt ngoại lệ `mssql-jdbc` | Pha B | `apps/identity/keycloak/Dockerfile`, `.trivyignore`, image local/compose |
| `KC_DB_URL_PROPERTIES=?socketTimeout=30&connectTimeout=10&tcpKeepAlive=true` | Pha A — kết nối treo tối đa 30 s thay vì ~15 phút | `components/keycloak-aws/deployment.yaml` |
| Probe `timeoutSeconds`: readiness 3 s, liveness 5 s (trước: mặc định 1 s) | Cùng bài học #203; lab thấy `context deadline exceeded` | như trên |

Nâng **MINOR** (26.7 → 26.8): scale Keycloak về 0 trước khi deploy bản mới (runbook `auth.md` §8) — `login-failures`
chuyển sang lưu DB nên có migration schema. Ghi chú nâng cấp 26.8.0 đã rà: không thay đổi phá vỡ nào đụng cấu hình
của repo (không X509, không IdP mapper, không bật `stateless`).

## 3. Lần chạy 2 — sau khi sửa

_(điền sau khi chạy lại cùng lệnh trên prod với Keycloak 26.8.0)_

## 4. Rủi ro còn lại (đã đo hoặc đã biết, chưa sửa)

| Rủi ro | Hậu quả | Cách sửa | Vì sao chưa làm |
|---|---|---|---|
| **1 NAT Gateway** ở `ap-southeast-1a` | Mất `1a` = mọi Pod mất đường ra AWS API (SQS/EventBridge/STS/ECR) → đơn hàng vẫn tạo (outbox giữ sự kiện) nhưng hóa đơn dừng tới khi AZ về; image mới không kéo được | 1 NAT mỗi AZ + route table private riêng mỗi AZ (module `vpc`) | +$1,4/ngày mỗi NAT; staging/prod ephemeral. Làm khi prod chạy thường trực |
| Pod ở AZ chết chỉ bị đuổi sau **300 s** | 5 phút chạy thiếu replica (vẫn phục vụ nhờ 2 AZ còn lại) | `tolerationSeconds` ngắn hơn cho `node.kubernetes.io/unreachable` | Đánh đổi: ngắn quá thì một lần chập mạng thoáng qua cũng đuổi Pod hàng loạt |
| ALB vẫn có node ở AZ chết (thí nghiệm không chặn subnet public) | Một phần kết nối mới tới IP ALB ở AZ đó có thể lỗi | Route 53 ARC zonal shift cho ALB | Chưa đo — cần chặn subnet public, mà đó cũng là nơi có NAT |

## 5. Tự kiểm tra

1. Vì sao chọn AZ chứa RDS primary thay vì AZ ngẫu nhiên?
2. NACL deny-all khác `kubectl drain` node ở điểm nào về **kiểu** lỗi ứng dụng nhìn thấy? (gợi ý: RST vs mất hút)
3. Vì sao 5 service Spring hồi phục trong 21 s mà Keycloak thì không — dù Pod Keycloak không ở AZ bị cô lập?
4. Vì sao readiness DOWN (không phải liveness) lại làm Keycloak hỏng *vô thời hạn*?
5. Vì sao `AvailabilityZone` của RDS không dùng được để đo thời gian failover?

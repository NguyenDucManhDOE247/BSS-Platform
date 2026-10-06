# Lab 10 — Mất 1 Availability Zone trên prod (2026-10-02 → 10-06)

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

**Giới hạn của 2 lần chạy đầu:** không chặn subnet **public**. Mất AZ thật còn làm mất node ALB và **NAT Gateway** ở AZ đó.
Lúc ấy module `vpc` chỉ có **1 NAT** (ở AZ đầu tiên, `ap-southeast-1a`): mất đúng AZ đó = mọi Pod mất đường ra Internet
(SQS, EventBridge, STS, ECR) → luồng order → hóa đơn dừng. Từ ADR-013 prod có **1 NAT mỗi AZ** và script có
`INCLUDE_PUBLIC=1` (chặn cả subnet public) — **lần chạy 3 (mục 3b)** đo đúng trường hợp đó.

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

### 2b. Lỗi thật thứ hai, lộ ra khi chuẩn bị lần chạy 2: HPA hạ prod về 2 replica

Trước lần chạy 2, namespace chỉ còn 16 Pod (lần 1: 22). Không Pod nào "mất": **HPA base có `minReplicas: 2`**, nên lúc
tải thấp HPA hạ 3 replica của overlay prod xuống 2 sau ~5 phút. `replicas: 3` trong overlay chỉ là số **lúc deploy**.

| Hệ quả đo được | Vì sao nguy hiểm |
|---|---|
| `kubectl get pdb`: `ALLOWED DISRUPTIONS 0` ở **5 service** (PDB prod `minAvailable: 2` + 2 replica) | Drain node, nâng cấp node group, Karpenter gom node — đều bị chặn ở prod (cùng loại lỗi PDB của dev, #203) |
| Cả 2 Pod `product-catalog` cùng nằm ở `1c` | Mất `1c` = mất hẳn catalog — đúng thứ lab này muốn chứng minh là không xảy ra |

**Sửa:** overlay prod patch HPA `minReplicas: 3` cho 6 service chạy 3 replica (`admin-console` giữ 2). Sau khi áp:
PDB cho phép 1 gián đoạn ở mọi service, Pod trải đủ 3 AZ.

## 3. Lần chạy 2 — Keycloak 26.8.0 + timeout DB + HPA min 3

Đưa lên prod **chỉ cho lab** bằng đúng công cụ của CD (`release-manifest.sh render`, runbook `cd-dev.md` §5): 7 service
giữ ảnh `v2.2.0`, chỉ Keycloak đổi sang ảnh do `cd-dev` build từ #215; scale Keycloak về 0 trước (nâng MINOR); `e2e-flow.sh
prod` **PASS** trước thí nghiệm. RDS primary lúc này ở `1a` (sau lần 1) → cô lập **`ap-southeast-1a`**, ép failover về `1b`.

```bash
OUT_DIR=results/az-outage-prod-run2 ./scripts/chaos-az-outage.sh prod ap-southeast-1a
```

| Đo | Lần 1 (26.7.5) | **Lần 2 (26.8.0)** |
|---|---|---|
| API catalog | 4 / 449 lỗi (0,89 %), trong 21 s | **6 / 446 (1,35 %)** — 5 timeout ở t = 0…25 s, 1 lỗi `500` ở t = 447 s (26 s sau khi trả mạng) |
| OIDC qua ALB | 371 / 448 lỗi (82,8 %), **không tự hồi phục** | **0 / 446** |
| Cluster Keycloak (`jgroups_ping`) | mất coordinator, **không bao giờ** ghép lại | lỗi `No coordinator found` 16:30:20 → 16:30:54, **tự ghép lại sau 34 s** ✅ |
| Readiness Keycloak | DOWN vô thời hạn (restart tay) | DOWN **t = 195 s → t = 963 s** (≈ 13 phút), rồi **tự Ready**, cả 2 Pod cùng 1 giây |
| Node / Pod | NotReady 1, 0 Pending | NotReady 1, 0 Pending |
| Sau thí nghiệm | — | `e2e-flow.sh prod` **PASS** |

**Bản sửa upstream (#51916) hoạt động:** cluster Keycloak tự ghép lại thay vì hỏng tới khi có người restart.

### 3.1 Còn lại: health check của Keycloak treo theo timeout TCP của kernel (~16 phút)

Readiness DOWN vì `KeycloakReadyHealthCheck` bị từ chối (`No executor queue space remaining`). Thread dump 2 lần cách
nhau 150 s (`results/az-outage-prod-run2/kc-threaddump*.txt`): **cùng một luồng** kẹt ở
`ConnectionPool.isHealthy → PgConnection.isValid → SSLSocket.read`, thời gian CPU không đổi. Pool vẫn khỏe (2 kết
nối sẵn sàng, 0 chờ); `pg_stat_activity` cho thấy mọi phiên của Keycloak ở primary mới đều `idle / ClientRead`. Lỗi
cuối cùng lúc **16:45:42 = 963 s sau khi cô lập ≈ thời gian kernel bỏ một kết nối TCP chết (`tcp_retries2 = 15`,
~15,5 phút)** — luồng chỉ được giải phóng khi kernel hủy socket tới primary cũ.

Lúc đó chưa giải thích được vì sao `socketTimeout=30` (đã nạp đúng — `kc.sh show-config`) không cắt lần đọc ấy —
lời giải ở mục 3.2.

**Ảnh hưởng thật trong 13 phút đó:** ALB vẫn trả trang đăng nhập nhờ *fail-open* (mọi target unhealthy → ALB gửi cho tất
cả) — đầu dò OIDC **0 lỗi là nhờ fail-open, không phải vì Keycloak "khỏe"**. Nhưng Service `keycloak` trong cluster
**không còn endpoint Ready**: service nào cần tải lại JWKS lúc đó sẽ lỗi (khóa đã cache thì không sao).

### 3.2 Nguyên nhân gốc + bản sửa (issue #217, 2026-10-05) — tái hiện trên máy, $0

**Manh mối:** trong thread dump, lần đọc đi vào `NioSocketImpl.implRead:309 → park(fd, POLLIN)` — nhánh **không
timeout** của JDK (nhánh có timeout là `timedRead`). Tức socket đó có `SO_TIMEOUT = 0` dù JDBC URL ghi `socketTimeout=30`.
Phải có ai đặt lại network timeout của kết nối.

**Chuỗi nguyên nhân (đọc mã nguồn 3 dự án):**

1. Keycloak ≥ 26.8.0 — chính bản vá [#51916](https://github.com/keycloak/keycloak/pull/51916) — gọi
   `connection.setNetworkTimeout(executor, staleness_timeout / 3)` trên **mỗi kết nối JDBC_PING2 mượn từ pool**.
2. Agroal (`ConnectionHandler.java:163`): khi kết nối được trả về mà network timeout đã bị đổi, nó đặt lại bằng
   `connectionFactoryConfiguration().networkTimeout()` — cấu hình **của Agroal**, mặc định `0` = vô hạn — chứ không
   phải giá trị pgjdbc đã đặt từ URL.
3. JDBC_PING2 chạy vài giây một lần ⇒ chẳng mấy chốc mọi kết nối trong pool mất `socketTimeout`. Primary biến mất
   im lặng ⇒ health check (`isHealthy → isValid`) đọc vô hạn ⇒ hàng đợi health đầy ⇒ readiness DOWN tới khi kernel
   bỏ socket.

Nói cách khác: bản vá cứu cluster JDBC_PING2 (mục 3) **đồng thời** vô hiệu hóa timeout của mọi kết nối khác — hai lỗi
nối đuôi nhau, và chỉ lần chạy 2 mới lộ cái thứ hai.

**Sửa:** `QUARKUS_DATASOURCE_JDBC_NETWORK_TIMEOUT=30S` (ánh xạ vào `networkTimeout` của Agroal, cùng giá trị với
`socketTimeout`) trong `components/keycloak-aws/deployment.yaml`.

**Kiểm chứng** — [`scripts/lab-keycloak-db-failover.sh`](../../scripts/lab-keycloak-db-failover.sh): đúng image
`apps/identity/keycloak`, 2 Postgres; `iptables DROP` mọi gói từ Keycloak tới primary cũ (mất hút như NACL), DNS chuyển
sang primary mới có cùng dữ liệu; đo `/health/ready` mỗi 2 s.

| | Chưa sửa (`NETWORK_TIMEOUT=`) | **Đã sửa (30S)** |
|---|---|---|
| `/health/ready` sau khi primary biến mất | không về 200 trong 240 s; để chạy tiếp: **tự Ready ở t = 936 s (15,6 phút)** — khớp prod (963 s) | **về 200 ổn định, lần lỗi cuối ở t = 26 s / 25 s** (3 lần chạy) |
| Log `No executor queue space remaining` | 132 dòng trong 240 s (820 dòng trong 936 s) | **0** |
| Thread dump | `isHealthy:629 → isValid:1604 → implRead:309 → park` — trùng từng dòng với prod | không còn luồng kẹt đọc |

`ci-keycloak` chạy bài lab này với image vừa build và **đọc 2 giá trị timeout từ manifest** (thiếu là dừng) — xóa nhầm env,
hoặc một bản Keycloak mới làm property thô của Quarkus hết tác dụng, là PR đỏ.

Bài học của chính bài lab: 2 lần đo đầu **vô nghĩa** vì Docker cấp cho "primary mới" đúng IP cũ của primary bị chặn
(nên nó cũng mất hút) — sửa bằng IP tĩnh. Kết quả "vẫn hỏng dù đã sửa" suýt bị tin là thật.

Đã chạy lại trên AWS với RDS thật ở lần chạy 3 (mục 3b): readiness DOWN ≈ 45 s thay vì ≈ 13 phút.

## 3b. Lần chạy 3 — `v2.3.0`, mất **cả** AZ (private + public), prod có NAT mỗi AZ (2026-10-06)

Bản `v2.3.0` do **CD** đưa lên (không còn "chỉ cho lab"): Keycloak 26.8.0 + `QUARKUS_DATASOURCE_JDBC_NETWORK_TIMEOUT=30S`
(#217) + HPA `minReplicas: 3`; prod dựng với **3 NAT** (mỗi subnet private đi ra qua NAT của đúng AZ mình — kiểm bằng
`describe-route-tables` trước thí nghiệm). `e2e-flow.sh prod` **PASS** trước thí nghiệm. RDS primary ở `1a`, standby `1b`.

```bash
INCLUDE_PUBLIC=1 OUT_DIR=results/az-outage-prod-run3 ./scripts/chaos-az-outage.sh prod   # AZ = ap-southeast-1a
```

Cô lập **cả hai** subnet của `1a` (private: 1 node, 7 Pod `bss`, 1 trong 2 Pod CoreDNS; public: node ALB + NAT của AZ) và
ép RDS failover `1a → 1b`. Đo thêm, ngoài 2 đầu dò của script:

- **Readiness Keycloak** mỗi 5 s (`kubectl get pods` + số endpoint Ready của Service `keycloak`).
- **Đường ra AWS API qua NAT**: từ 4 Pod ở AZ **không** bị cô lập (`order-management` + `billing-service` ở `1b`, `1c`),
  `kubectl exec` mở TCP 443 tới endpoint SQS, EventBridge, STS (tên miền → cần cả DNS trong cluster lẫn NAT).
- **Đo đối chứng** 7 phút ngay sau thí nghiệm, prod khỏe, cùng máy đo: 2 đầu dò cũ + một trang ngoài
  (`checkip.amazonaws.com`) + `kubectl get --raw /readyz`.

| Đo | Lần 2 (private, 1 NAT) | **Lần 3 (private + public, 3 NAT)** |
|---|---|---|
| **Readiness Keycloak** | DOWN t = 195 → 963 s (≈ 13 phút) | **DOWN t ≈ 27–37 → 74 s (≈ 45 s)**, 2 Pod Ready lại cùng lúc ✅ |
| Log Keycloak | `No executor queue space remaining` hàng trăm dòng; mất coordinator 34 s | **0 dòng** `No executor queue space`, **0** lần mất coordinator |
| OIDC qua ALB | 0 / 446 (nhờ ALB fail-open) | 11 / 398: 2 timeout (t = 23, 47 s) + **7 × `503` ở t = 58–68 s** (lúc cả 2 Pod NotReady) + 2 lỗi nhiễu máy đo (xem dưới) |
| **API catalog** | 6 / 446 (1,35 %) — 5 timeout ở t = 0…25 s | 16 / 398 (4,02 %): **8 timeout liên tiếp ở t = −2…47 s** (API không phục vụ được ≈ 55 s; t = 0 ghi sau khi đổi NACL xong cả 2 subnet nên lỗi đầu rơi vào t = −2), 8 lỗi còn lại là nhiễu máy đo |
| **Đường ra AWS API** từ Pod ở `1b`/`1c` | không đo (1 NAT ở `1a` ⇒ lẽ ra mất hết) | t = 60 → 424 s (AZ `1a` + NAT của nó vẫn chết): **207 / 208 lần mở được** ✅ — nhưng **8 / 8 lần đầu (t = 8…51 s) thất bại** |
| RDS | — | `rebooting` t ≈ 6 → `available` t ≈ 73 s (trường `AvailabilityZone` đổi ở t ≈ 185 s) |
| Node `1a` | NotReady 1 | NotReady t ≈ 46–60 s → Ready t ≈ 448 s (mạng trả ở t = 424) |
| Pod | 0 Pending | Pod ở `1a` bị đuổi ở t = 346 s; **1 Pod Pending 99 s** (`customer-service` thay thế: `3 Insufficient cpu`) |
| Sau thí nghiệm | `e2e-flow.sh prod` PASS | `e2e-flow.sh prod` **PASS**; không còn NACL thí nghiệm |

**Điều lần 3 chứng minh được**

1. **#217 đã sửa trên RDS thật.** Readiness của Keycloak tự hồi phục sau ≈ 45 s (lần 2: ≈ 13 phút), khớp với bài lab trên
   máy (26 s). Lần này ALB có trả `503` trong ≈ 10 s — con số "0 lỗi" của lần 2 là nhờ fail-open, không phải vì tốt hơn.
2. **NAT mỗi AZ hoạt động.** Suốt 6 phút AZ `1a` chết cùng NAT của nó, Pod ở `1b`/`1c` vẫn mở được kết nối tới SQS,
   EventBridge, STS (207/208; lần hỏng duy nhất trùng một nhịp nhiễu của máy đo). Với 1 NAT ở `1a`, cùng thí nghiệm này sẽ
   cắt toàn bộ đường ra.

**Điều lần 3 làm lộ ra (chưa sửa — mục 4)**

1. **≈ 55 s đầu tệ hơn hai lần trước** (API 8 timeout liên tiếp; lần 1–2: 21–25 s), và trong đúng khoảng đó **mọi** lần thử
   đường ra từ Pod ở AZ *khỏe* cũng hỏng (8/8), rồi cùng hết khi node `1a` bị đánh dấu NotReady (t ≈ 46–60 s).
   Giải thích khớp nhất với số liệu — **suy luận, chưa đo tách riêng**: 1 trong 2 Pod CoreDNS nằm ở `1a`; cho tới khi node
   NotReady, Service `kube-dns` vẫn chia ≈ 50 % truy vấn cho Pod đã chết, mỗi truy vấn rơi vào đó chờ 5 s. Một tên như
   `sqs.ap-southeast-1.amazonaws.com` bị `ndots:5` nhân thành ~10 truy vấn ⇒ gần như chắc chắn dính ít nhất một lần.
   Lần 1–2 không ghi CoreDNS nằm ở đâu nên không so được. Lần sau: thêm đầu dò DNS riêng (và thử bằng IP) để tách DNS
   khỏi NAT.
2. **Prod không còn chỗ khi mất 1 node:** 3 node còn lại ở 98–99 % CPU `requests` ⇒ 1 Pod thay thế phải chờ node `1a`
   quay lại (99 s). `customer-service` vẫn còn 2 replica ở 2 AZ nên không gián đoạn, nhưng mất AZ lâu hơn = chạy thiếu
   replica suốt thời gian đó. Nguyên nhân là trần 8 vCPU của tài khoản (ADR-006), không phải thiếu cấu hình.
3. **AZ quay lại nhưng Pod không tự trải lại:** sau thí nghiệm Pod `bss` theo AZ là **1 / 7 / 14** (trước: 7 / 6 / 9).
   Topology spread chỉ có tác dụng lúc xếp lịch. Nếu ngay sau đó mất `1c` thì mất 14/22 Pod cùng lúc.
4. **`e2e-flow.sh` không chạy được giữa lúc mất AZ**: script dừng ở điều kiện "mọi Pod phải Ready" (Pod ở node chết đang
   `Terminating`). Vì thế luồng order → hóa đơn **trong lúc** mất AZ chưa được đo; bằng chứng NAT là đầu dò TCP ở trên.

**Độ tin cậy của phép đo.** Đo đối chứng trên prod khỏe: API 2/153 lỗi, OIDC 1/153, trang ngoài 1/153, `kubectl` 2/153 —
các lỗi **trùng giây nhau** trên những đích không liên quan gì tới nhau ⇒ máy đo (WSL trên laptop) tự rớt mạng vài giây
mỗi ≈ 2 phút, tạo sàn nhiễu ≈ 1 %. Trong lần 3, 8 lỗi API theo cặp ở t ≈ 148/160, 360/372, 480/491, 600/611 (kéo dài cả
sau khi mạng đã trả) đúng mẫu đó, và các vòng `kubectl` chạy song song cũng khựng ở cùng giây. Hệ quả: **tỉ lệ % lỗi của
bài lab này không chính xác hơn ±1 %**; thứ đáng tin là các **chuỗi lỗi liên tiếp** và mốc thời gian. Lần 1–2 đo từ cùng
laptop nhưng không có phép đo đối chứng, nên không biết lúc đó sàn nhiễu có giống vậy không.

## 4. Rủi ro còn lại (đã đo hoặc đã biết, chưa sửa)

| Rủi ro | Hậu quả | Cách sửa | Vì sao chưa làm |
|---|---|---|---|
| ~~1 NAT Gateway ở `ap-southeast-1a`~~ — **đã sửa và đã đo** ([ADR-013](../adr/ADR-013-runner-cd-trong-vpc.md), lần 3) | Trước: mất `1a` = mọi Pod mất đường ra AWS API (SQS/EventBridge/STS/ECR) | Prod: 1 NAT + 1 route table private mỗi AZ (`nat_gateway_per_az`) | — |
| Pod ở AZ chết chỉ bị đuổi sau **300 s** | 5 phút chạy thiếu replica (vẫn phục vụ nhờ 2 AZ còn lại) | `tolerationSeconds` ngắn hơn cho `node.kubernetes.io/unreachable` | Đánh đổi: ngắn quá thì một lần chập mạng thoáng qua cũng đuổi Pod hàng loạt |
| ALB vẫn có node ở AZ chết | Một phần kết nối mới tới IP ALB ở AZ đó có thể lỗi | Route 53 ARC zonal shift cho ALB | Lần 3 (chặn subnet public) **không thấy** lỗi kéo dài từ 1 máy đo, nhưng không ghi lại DNS của ALB nên chưa biết IP ấy bị gỡ sau bao lâu |
| **CoreDNS có Pod ở AZ chết** (lần 3 — suy luận từ số liệu) | ≈ 50 s đầu: tra DNS trong cluster chậm/hỏng với **mọi** Pod, kể cả ở AZ khỏe | NodeLocal DNSCache; hoặc `ndots` thấp hơn cho các service gọi tên miền ngoài | Chưa đo tách riêng DNS khỏi NAT — làm trước khi chọn cách sửa |
| **Không còn CPU dự phòng khi mất 1 node** (lần 3) | Pod thay thế Pending tới khi node quay lại | Thêm node / hạ `requests` | Trần 8 vCPU của tài khoản (ADR-006) — prod đã dùng 8/8 |
| **Pod không tự trải lại sau khi AZ quay lại** (lần 3: 1 / 7 / 14) | Mất tiếp AZ đang dồn Pod = mất quá nửa số Pod | Descheduler (`RemovePodsViolatingTopologySpreadConstraint`) hoặc `rollout restart` sau sự cố | Thêm một thành phần phải nuôi; môi trường ephemeral — ghi vào quy trình sau sự cố là đủ lúc này |
| **Máy đo tự rớt mạng** (sàn nhiễu ≈ 1 %) | Tỉ lệ % lỗi của lab không chính xác hơn ±1 % | Chạy đầu dò từ trong AWS, hoặc thêm đích đối chứng vào `chaos-az-outage.sh` | Chưa làm — mới phát hiện ở lần 3 |

## 5. Tự kiểm tra

1. Vì sao chọn AZ chứa RDS primary thay vì AZ ngẫu nhiên?
2. NACL deny-all khác `kubectl drain` node ở điểm nào về **kiểu** lỗi ứng dụng nhìn thấy? (gợi ý: RST vs mất hút)
3. Vì sao 5 service Spring hồi phục trong 21 s mà Keycloak thì không — dù Pod Keycloak không ở AZ bị cô lập?
4. Vì sao readiness DOWN (không phải liveness) lại làm Keycloak hỏng *vô thời hạn*?
5. Vì sao `AvailabilityZone` của RDS không dùng được để đo thời gian failover?
6. Overlay prod ghi `replicas: 3` nhưng cluster chạy 2 — ai thắng, và vì sao PDB `minAvailable: 2` biến điều đó thành lỗi?
7. Lần 2 đầu dò OIDC 0 lỗi trong khi cả 2 Pod Keycloak NotReady 13 phút. ALB làm gì để ra con số đó, và vì sao không được
   đọc nó thành "Keycloak khỏe"?
8. (3.2) Vì sao `socketTimeout=30` trong JDBC URL không đủ, và thread dump cho biết điều đó ở dòng nào?
9. (3.2) Hai lần đo đầu của lab trên máy cho kết quả "đã sửa mà vẫn hỏng". Sai ở đâu, và bài học chung là gì?
10. (3b) Lần 3 ghi 16 lỗi API nhưng chỉ 8 lỗi được tính cho sự cố. Dựa vào đâu để loại 8 lỗi kia, và vì sao phải có phép
    đo đối chứng mới nói được điều đó?
11. (3b) Pod ở AZ khỏe có NAT riêng mà 50 s đầu vẫn không gọi được SQS. Thành phần nào nằm giữa, và vì sao `ndots:5` làm
    chuyện tệ hơn?
12. (3b) Vì sao sau khi AZ quay lại, Pod không tự trải đều về 3 AZ?

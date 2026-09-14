# 30 — Ôn tập: flashcards, bài giải thích lại, câu hỏi phỏng vấn

> Cách dùng: che đáp án (bấm mở `<details>` sau khi tự trả lời **thành tiếng**). Sai câu nào → đánh dấu ✗ và ôn lại
> ở lượt sau. Lịch ôn: **+1, +3, +7, +21, +60 ngày** sau khi học bài tương ứng. Ghi ngày ôn vào [nhật ký](nhat-ky-hoc-tap.md).

---

## A. Tổng quan & domain (bài 00)

1. BSS khác OSS thế nào? Cho 1 ví dụ mỗi loại.
   <details><summary>Đáp án</summary>BSS hướng khách hàng/tiền/sản phẩm (đăng ký gói, hóa đơn); OSS hướng mạng lưới (kích hoạt SIM, cấp băng thông).</details>
2. 4 API TMF trong dự án và service tương ứng?
   <details><summary>Đáp án</summary>TMF629 customer-service, TMF620 product-catalog, TMF622 order-management, TMF678 billing-service.</details>
3. Vì sao order → billing đi qua hàng đợi thay vì gọi HTTP?
   <details><summary>Đáp án</summary>Tách phụ thuộc (billing chết không làm hỏng đặt hàng), tự nhiên có retry/đệm tải, thêm consumer mới không sửa order. Đổi lại: eventual consistency, phải idempotent.</details>
4. Trang Hóa đơn vì sao phải poll mỗi 5 giây?
   <details><summary>Đáp án</summary>Hóa đơn được tạo bất đồng bộ sau khi sự kiện đi qua outbox → EventBridge → SQS → billing.</details>

## B. Backend (bài 10)

5. `@Transactional` hoạt động nhờ cơ chế gì? Khi nào nó vô tác dụng?
   <details><summary>Đáp án</summary>Proxy AOP bọc bean. Vô tác dụng khi gọi nội bộ `this.method()` (không qua proxy), method không public (với proxy mặc định), hoặc gọi trên object tự `new`.</details>
6. Dual-write problem là gì? Outbox giải thế nào?
   <details><summary>Đáp án</summary>Ghi DB và gửi message là 2 hệ thống, không có transaction chung → một bên thành công một bên thất bại. Outbox ghi sự kiện vào bảng trong cùng transaction với dữ liệu, tiến trình khác đọc và gửi, thử lại đến khi thành công.</details>
7. Outbox cho at-least-once hay exactly-once? Hệ quả?
   <details><summary>Đáp án</summary>At-least-once → consumer phải idempotent theo một khóa ổn định.</details>
8. Vì sao dedup theo `envelope.id` của EventBridge là sai (B-11)?
   <details><summary>Đáp án</summary>Mỗi lần PutEvents sinh id mới; publish lại cùng dòng outbox → id khác → coi như sự kiện mới → hóa đơn trùng. Nên dedup theo id dòng outbox / orderId.</details>
9. `FOR UPDATE SKIP LOCKED` dùng để làm gì trong outbox?
   <details><summary>Đáp án</summary>Nhiều pod cùng drain: mỗi pod khóa các dòng mình lấy, pod khác bỏ qua dòng đang bị khóa → không gửi trùng do đọc đồng thời.</details>
10. `ddl-auto: validate` vs `update`?
    <details><summary>Đáp án</summary>validate: chỉ kiểm entity khớp bảng, lệch thì không khởi động — Flyway sở hữu schema. update: Hibernate tự sửa DB — không kiểm soát, nguy hiểm ở prod.</details>
11. Sửa file `V1__init.sql` đã chạy thì sao?
    <details><summary>Đáp án</summary>Checksum lệch → Flyway validate fail → app không khởi động. Phải tạo migration mới V2.</details>
12. 400 vs 422 vs 409?
    <details><summary>Đáp án</summary>400 request hỏng cú pháp; 422 đúng cú pháp nhưng vi phạm ràng buộc dữ liệu; 409 xung đột trạng thái (vd. email trùng).</details>
13. SQS: visibility timeout, DeleteMessage, redrive policy?
    <details><summary>Đáp án</summary>Message ẩn trong khoảng timeout sau khi nhận; DeleteMessage = ACK; nhận quá maxReceiveCount mà không xóa → sang DLQ.</details>
14. IRSA trên Pod: SDK lấy credential qua những bước nào? Thiếu gì thì hỏng (B-19)?
    <details><summary>Đáp án</summary>Webhook tiêm AWS_ROLE_ARN + token file → SDK đọc token → STS AssumeRoleWithWebIdentity → credential tạm. AWS SDK v2 cần module `sts` trên classpath.</details>
15. Vì sao `order_item.product_offering_id` không có FOREIGN KEY?
    <details><summary>Đáp án</summary>Database-per-service: offering thuộc DB của service khác.</details>
16. Vì sao tiền dùng `BigDecimal`/`NUMERIC`?
    <details><summary>Đáp án</summary>Số thực nhị phân không biểu diễn chính xác số thập phân (0.1 + 0.2 ≠ 0.3).</details>

## C. Docker & local (bài 11, 12)

17. Multi-stage build lợi gì?
    <details><summary>Đáp án</summary>Image runtime chỉ chứa JRE + JAR: nhỏ hơn, ít CVE, không lộ công cụ build.</details>
18. Vì sao `COPY pom.xml` trước `COPY src/`?
    <details><summary>Đáp án</summary>Layer tải dependency được cache, chỉ build lại khi pom đổi.</details>
19. `-XX:MaxRAMPercentage=75` với limit 1Gi?
    <details><summary>Đáp án</summary>Heap tối đa ~768Mi; phần còn lại cho metaspace, thread stack, buffer.</details>
20. Vì sao Nginx non-root phải nghe port ≥ 1024 và cần chỗ ghi pid?
    <details><summary>Đáp án</summary>Port < 1024 cần quyền đặc biệt (CAP_NET_BIND_SERVICE); nginx ghi pid/cache — user thường không ghi được vào /run của root → dùng nginx-unprivileged hoặc volume ghi được.</details>
21. 2 lỗi LocalStack không phát hiện được?
    <details><summary>Đáp án</summary>Thiếu quyền IAM/trust policy (IRSA, access entry), thiếu queue policy cho EventBridge, thiếu module sts.</details>

## D. Kubernetes & Kustomize (bài 13)

22. startup / liveness / readiness — fail thì kubelet làm gì?
    <details><summary>Đáp án</summary>startup: chưa pass thì chưa chạy 2 probe kia, quá ngưỡng thì restart. liveness: restart container. readiness: rút khỏi Service endpoints, không restart.</details>
23. Vì sao liveness không kiểm DB?
    <details><summary>Đáp án</summary>DB chậm → mọi pod bị restart cùng lúc → sự cố lan rộng, không giúp gì.</details>
24. `maxSurge: 1, maxUnavailable: 0` nghĩa là gì?
    <details><summary>Đáp án</summary>Tạo pod mới trước (vượt 1), pod mới Ready rồi mới xóa pod cũ → không giảm năng lực phục vụ; cần tài nguyên dư cho 1 pod.</details>
25. configMapGenerator có hash suffix để làm gì?
    <details><summary>Đáp án</summary>Đổi nội dung → tên mới → Pod template đổi → tự rolling restart; tránh Pod dùng config cũ.</details>
26. HPA và `replicas:` — cái nào thắng?
    <details><summary>Đáp án</summary>HPA (nó liên tục chỉnh spec.replicas trong khoảng min–max).</details>
27. PDB `minAvailable: 1` với 1 replica gây gì?
    <details><summary>Đáp án</summary>Không drain/evict được pod → node không gỡ được (nâng cấp, Karpenter consolidation kẹt).</details>
28. `target-type: ip` của ALB?
    <details><summary>Đáp án</summary>ALB gửi thẳng tới IP Pod (VPC CNI cấp IP VPC cho Pod), không qua NodePort.</details>
29. Công thức max pod của t3.medium?
    <details><summary>Đáp án</summary>ENI × (IP/ENI − 1) + 2 = 3 × 5 + 2 = 17.</details>

## E. Terraform & AWS (bài 14)

30. Vì sao `default` của variable không gọi được `jsonencode`?
    <details><summary>Đáp án</summary>Default phải là giá trị hằng; hàm đặt trong locals hoặc chỗ gọi module.</details>
31. `count` vs `for_each`?
    <details><summary>Đáp án</summary>count theo chỉ số — xóa phần tử giữa làm dịch chỉ số, tạo lại tài nguyên; for_each theo khóa ổn định.</details>
32. `cidrsubnet("10.10.0.0/16", 8, 10)`?
    <details><summary>Đáp án</summary>10.10.10.0/24 — private subnet AZ đầu của dev.</details>
33. Trust policy IRSA kiểm những gì?
    <details><summary>Đáp án</summary>Principal Federated = OIDC provider của cluster; Action AssumeRoleWithWebIdentity; sub = system:serviceaccount:ns:sa; aud = sts.amazonaws.com.</details>
34. Vì sao VPC endpoint không thay được NAT cho Helm addon?
    <details><summary>Đáp án</summary>Image ở quay.io/registry.k8s.io/docker.io... là Internet, không có endpoint AWS nào tới đó.</details>
35. Tài nguyên nào không nên nằm trong state dev (B-33)?
    <details><summary>Đáp án</summary>ECR dùng chung, GitHub OIDC provider, deployer roles — sống lâu hơn môi trường dev.</details>
36. Vì sao destroy VPC hay treo trên EKS?
    <details><summary>Đáp án</summary>ALB/ENI/node Karpenter do controller tạo, không nằm trong state → còn phụ thuộc. Xóa Ingress/NodePool trước.</details>
37. Quyền `eks:DescribeCluster` có đủ để `kubectl apply` không?
    <details><summary>Đáp án</summary>Không — cần access entry (hoặc aws-auth) ánh xạ IAM principal sang quyền Kubernetes.</details>

## F. CI/CD (bài 15)

38. `sub` của job có `environment: production`?
    <details><summary>Đáp án</summary>`repo:OWNER/REPO:environment:production`.</details>
39. Vì sao cd-dev hiện tại phá service không đổi (B-50)?
    <details><summary>Đáp án</summary>Sửa image tag trong runner nhưng không commit; apply cả overlay nên service khác nhận tag placeholder không tồn tại.</details>
40. Build once deploy many gãy thế nào với path-filter (B-51)?
    <details><summary>Đáp án</summary>Mỗi SHA chỉ có image của service thay đổi; promotion theo SHA thiếu image các service khác.</details>
41. Vì sao ghim action theo SHA?
    <details><summary>Đáp án</summary>Tag có thể bị di chuyển sang commit độc hại (sự cố tj-actions 3/2025); SHA bất biến.</details>

## G. Platform & observability (bài 16)

42. Vì sao `prometheus.io/scrape` không chạy với kube-prometheus-stack?
    <details><summary>Đáp án</summary>Operator chỉ sinh scrape config từ ServiceMonitor/PodMonitor; annotation chỉ có ý nghĩa khi tự viết relabel_configs.</details>
43. Micrometer cần gì để có p95 trong Prometheus?
    <details><summary>Đáp án</summary>Bật percentiles-histogram cho http.server.requests → xuất `_bucket`.</details>
44. `rate()` dùng với loại metric nào?
    <details><summary>Đáp án</summary>Counter.</details>
45. HPA cần gì để đọc CPU?
    <details><summary>Đáp án</summary>metrics-server (Resource Metrics API) + requests CPU trên container.</details>
46. Error budget SLO 99.9%/30 ngày?
    <details><summary>Đáp án</summary>0.1% × 43.200 phút ≈ 43,2 phút.</details>
47. Karpenter vs Cluster Autoscaler?
    <details><summary>Đáp án</summary>CA scale Auto Scaling Group có loại máy cố định; Karpenter tạo EC2 trực tiếp theo nhu cầu Pod, chọn loại máy linh hoạt, gom node. Đổi lại IAM/interruption phức tạp hơn.</details>

---

## H. Bài "giải thích lại" (Feynman) — viết 10 dòng mỗi bài vào nhật ký

1. Giải thích cho bạn năm 2: vì sao đặt hàng xong vài giây mới có hóa đơn, và vì sao không mất hóa đơn khi hệ thống sự kiện sập.
2. Giải thích cho người vận hành: Pod lấy quyền đọc SQS như thế nào mà không có access key.
3. Giải thích cho thầy: vì sao Terraform của dự án chưa chạy được và bạn đã sửa thế nào.
4. Giải thích cho nhà tuyển dụng: khác biệt giữa pipeline Jenkins trong đồ án và GitHub Actions trong dự án, cái nào bạn chọn cho công ty 10 người.
5. Giải thích lỗi B-10 bằng một sơ đồ 5 bước.

## I. Câu hỏi phỏng vấn dựa trên dự án (tự luyện trả lời 2 phút/câu)

1. Kể về kiến trúc hệ thống bạn đã làm. Nếu tải tăng 100 lần, bạn đổi gì trước?
2. Làm sao đảm bảo không mất sự kiện và không xử lý trùng giữa 2 service?
3. Bạn quản lý secret thế nào? Vì sao không dùng K8s Secret thuần?
4. Bạn giảm chi phí môi trường dev thế nào? Con số cụ thể?
5. Kể về lỗi khó nhất bạn gặp (gợi ý: B-10 hoặc B-50) — nguyên nhân gốc, cách phát hiện, cách ngăn tái diễn.
6. Vì sao chọn Kustomize thay Helm cho app nhưng dùng Helm cho addon?
7. Mô tả quy trình từ merge PR đến prod. Rollback thế nào? DB migration khi rollback?
8. Monitoring: bạn đo gì, alert gì, ai nhận, runbook ra sao?
9. So sánh VPC endpoint và NAT Gateway về chi phí và chức năng.
10. IRSA và EKS Pod Identity khác nhau thế nào?

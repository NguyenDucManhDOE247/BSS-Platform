# ADR-002 — Mạng cho môi trường dev (NAT Gateway vs VPC Endpoints)

- **Trạng thái:** Chấp nhận (Accepted)
- **Ngày:** 2026-09-22
- **Giai đoạn:** 4 — Terraform + bootstrap AWS

## Bối cảnh

Thiết kế ban đầu của `environments/dev` (CLAUDE.md §4, `modules/vpc`) đặt node EKS trong private
subnet, **không có NAT Gateway**, thay bằng 5 VPC Interface Endpoint (`ecr.api`, `ecr.dkr`,
`secretsmanager`, `logs`, `sts`) + 1 S3 Gateway Endpoint — với lý do "VPC Endpoint rẻ hơn NAT
Gateway". Đây là **B-32**, một trong 13 lỗi P0 phát hiện ở `learning/01`.

Kiểm tra lại cả hai vế của lý do này:

**1. Có chạy được không?** Để một node EKS + addon + ứng dụng hoạt động, cluster cần gọi ra
ngoài tới: EKS API (✅ private endpoint), ECR + S3 (✅ có endpoint), **EC2** (❌ VPC CNI cần nó để
cấp IP cho mỗi Pod — không có endpoint), **STS** (✅), **ELB** (❌ AWS Load Balancer Controller
cần nó để tạo ALB — không có endpoint), **SQS/EventBridge** (❌ billing-service/order-management
cần — không có endpoint), **SSM, X-Ray** (❌)... và quan trọng nhất: mọi Helm chart trong
`platform/` (ALB Controller, Karpenter, Secrets Store CSI, Fluent Bit, OTel Collector,
kube-prometheus-stack) kéo image từ `quay.io`, `registry.k8s.io`, `public.ecr.aws`, Docker Hub —
**không VPC Endpoint nào thay được Internet** cho các domain này. Kết luận: thiết kế cũ
**không chạy được**, sẽ kẹt ở bước cài addon đầu tiên với `ImagePullBackOff`.

**2. Có rẻ hơn không?** Interface Endpoint tính phí ~$0.013/giờ **× mỗi AZ**. Dev chạy 2 AZ → 5
endpoint × 2 AZ ≈ $0.13/giờ ≈ **~$3.1/ngày**. Một NAT Gateway ≈ $0.059/giờ ≈ **~$1.4/ngày** (+phí
dữ liệu/GB, thường nhỏ ở quy mô học tập). → **Đắt hơn NAT**, không rẻ hơn như giả định ban đầu.

## Các phương án đã cân nhắc

| # | Phương án | Chạy được? | 💰 ước tính/ngày (dev, 2 AZ) | Ghi chú |
|---|---|---|---|---|
| A | Giữ nguyên: 5 interface endpoint, không NAT | ❌ | ~$3.1 | Vừa hỏng vừa đắt hơn phương án được chọn — loại ngay |
| B | Đủ bộ ~12 interface endpoint (thêm ec2, elb, sqs, events, ssm, xray...) + tự mirror mọi image Helm chart vào ECR | ✅ | ~$7.5 | Đúng mô hình "private cluster" doanh nghiệp thật, nhưng đòi hỏi tự dựng pipeline mirror image — quá nhiều việc phụ so với giá trị học được ở Giai đoạn 4 |
| C | **1 NAT Gateway + S3 Gateway Endpoint (miễn phí), bỏ interface endpoint** | ✅ | ~$1.4 + phí dữ liệu | **Chọn phương án này** |
| D | Node đặt ở public subnet (có IP public), Security Group chặt, không NAT | ✅ | ~$0 thêm | Rẻ nhất, nhưng node có IP public trực tiếp trên Internet — chấp nhận được cho lab cá nhân, **không phù hợp để luyện tập mô hình prod thật** |

## Quyết định

Chọn **phương án C**: bật `enable_nat_gateway = true` cho `dev` (khớp staging/prod, không còn là
trường hợp đặc biệt), tắt interface endpoint (`enable_interface_endpoints = false`), giữ lại S3
Gateway Endpoint (miễn phí, luôn bật — xem `modules/vpc/main.tf`).

**Vì sao không chọn D dù rẻ hơn:** ngân sách AWS cho dự án này là ngân sách cá nhân, không bị áp
lực chi phí ($1.4/ngày là chấp nhận được — xem `learning/bss-platform-phase0-decisions`), và mục
tiêu dự án là **luyện tập một mô hình gần với production thật** (đề tài nghiên cứu/portfolio, không
chỉ bài tập). Public subnet cho node NAT (dù có SG chặt) dạy sai thói quen — production không bao
giờ đặt node worker ra Internet trực tiếp. NAT Gateway giữ đúng ranh giới "private subnet cho
workload" mà staging/prod đã áp dụng, nên dev không còn là ngoại lệ kiến trúc.

**Vì sao không chọn B:** giá trị học thêm được (tự mirror image, quản lý interface endpoint đầy
đủ) không tương xứng với công sức bỏ ra ở giai đoạn hiện tại — CLAUDE.md §2 đã nêu nguyên tắc
"không over-engineer". Có thể quay lại phương án B sau này như một bài tập riêng về private
cluster nếu muốn (ghi trong `learning/`).

## Hệ quả

- ✅ `terraform apply` dev không còn kẹt ở bước cài Helm chart addon vì thiếu Internet.
- ✅ Cấu trúc mạng dev/staging/prod nhất quán — không còn 2 mô hình khác nhau cần nhớ.
- ✅ Chi phí mạng giảm từ ~$3.1/ngày (phương án cũ, mà còn không chạy được) xuống ~$1.4/ngày +
  phí dữ liệu.
- ⚠️ Node vẫn cần đi qua NAT cho *mọi* traffic ra ngoài (kể cả traffic tới AWS API) — chậm hơn
  một chút so với PrivateLink trực tiếp, nhưng không đáng kể ở quy mô dev.
- ⚠️ 1 NAT Gateway = single point of failure về mạng cho dev (chấp nhận được — dev không cần HA).
  Prod cũng đang dùng 1 NAT dù comment cũ ghi "HA" — đây là nợ kỹ thuật **khác** (B-39, xem
  `infrastructure/terraform/environments/prod/main.tf`), không phải quyết định của ADR này.

## Tự kiểm tra (đọc `learning/14-terraform-aws.md` mục 14 câu 4 trước khi xem đáp án)

Vì sao interface endpoint (dù đủ 12 cái) vẫn không thay được NAT cho việc kéo image Helm chart từ
`quay.io`? → Vì interface endpoint chỉ tồn tại cho **dịch vụ AWS cụ thể** (mỗi endpoint là một
PrivateLink tới một service AWS duy nhất, có DNS riêng) — nó không phải một cổng ra Internet vạn
năng. `quay.io`, `registry.k8s.io`, Docker Hub là hạ tầng của bên thứ ba, không phải dịch vụ AWS,
nên không có — và không thể có — VPC Endpoint nào cho chúng.

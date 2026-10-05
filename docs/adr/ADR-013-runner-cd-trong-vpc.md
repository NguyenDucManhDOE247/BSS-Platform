# ADR-013 — Runner CD trong VPC (CodeBuild) để khóa endpoint EKS; NAT mỗi AZ ở prod

- **Trạng thái:** Chấp nhận (Accepted) — đóng ngoại lệ "EKS endpoint `0.0.0.0/0` khi demo" (CLAUDE.md §10, từ GĐ6) và
  rủi ro "1 NAT là điểm chết đơn" ([Lab 10](../labs/10-az-outage.md) §4).
- **Ngày:** 2026-10-05
- **Liên quan:** [ADR-005](ADR-005-nguon-su-that-phien-ban-cd.md) (CD), [ADR-006](ADR-006-staging-prod-ephemeral.md)
  (staging/prod ephemeral — nơi ghi ràng buộc endpoint ↔ runner), [ADR-002](ADR-002-mang-dev.md) (mạng).

## Bối cảnh

CLAUDE.md §10 yêu cầu endpoint public của EKS **giới hạn CIDR** ở prod. Từ GĐ6 quy tắc đó bị vi phạm có chủ đích:
runner do GitHub host không có IP cố định (hàng nghìn dải, đổi liên tục; EKS nhận tối đa 40 CIDR), nên `kubectl` trong
CD chỉ chạy được khi `public_access_cidrs = ["0.0.0.0/0"]`. Lý do chấp nhận lúc đó: API server vẫn cần chữ ký IAM +
EKS access entry, cluster chỉ sống vài giờ. Đó là lý do đúng cho một buổi demo — và sai cho một prod chạy thường trực.

Lab 10 (mất 1 AZ) ghi thêm một lỗ hổng cùng loại "biết mà để đó": cả VPC có **1 NAT Gateway** ở AZ đầu tiên.

## Quyết định

### 1. Job deploy của cd-staging / cd-prod chạy trên runner CodeBuild **trong VPC** của môi trường

| Phương án | Vì sao không / có |
|---|---|
| Giữ `0.0.0.0/0` | Không còn lý do khi đã có cách rẻ để bỏ |
| CD tự thêm IP runner vào `public_access_cidrs` rồi gỡ | Role CD cần `eks:UpdateClusterConfig` (không giới hạn được "chỉ thêm 1 IP"), mỗi lần đổi mất vài phút, job chết giữa chừng thì IP nằm lại |
| EC2 self-hosted runner | Một máy phải vá, giám sát, và là nơi giữ credential sống lâu |
| GitOps kéo (ArgoCD) | Đúng hướng dài hạn, nhưng thay cả mô hình CD — ADR-005 đã ghi điều kiện xem lại (> 10 service) |
| **CodeBuild làm runner GitHub Actions, gắn vào subnet private (chọn)** | Không có máy để nuôi; mỗi job một container mới như runner của GitHub; trả theo phút build; sinh ra và mất đi cùng môi trường ephemeral; workflow chỉ đổi `runs-on` |

Hệ quả kiến trúc:

- `modules/ci-runner`: project CodeBuild + webhook `WORKFLOW_JOB_QUEUED`, security group **chỉ có egress**, và một luật
  ingress 443 trên cluster security group **từ đúng security group của runner**. Runner gọi API server qua endpoint
  **private** (bật sẵn từ đầu) → `public_access_cidrs` của staging/prod chỉ còn IP của người vận hành.
- **Runner không mang quyền deploy.** Role của project chỉ đủ chạy container trong VPC + ghi log + dùng kết nối
  GitHub. Job vẫn lấy quyền như cũ: GitHub OIDC → `bss-github-deployer-<env>` (trust theo GitHub Environment, B-39;
  prod vẫn phải duyệt tay). Chiếm được runner không cho thêm quyền gì ngoài thứ job đó vốn có.
- **Kết nối GitHub (CodeConnections) ở state `shared`** — bước ủy quyền GitHub App phải làm tay một lần trong console;
  để ở state sống lâu thì không phải làm lại mỗi buổi (cùng lý do với zone DNS — ADR-012).
- dev **không** dùng runner này: endpoint dev mở là thiết kế (CD chạy mỗi lần merge, cluster rẻ, không có dữ liệu thật).

### 2. Job "preflight" + role chỉ-đọc `bss-github-cd-preflight`

Môi trường chưa dựng ⇒ project runner không tồn tại ⇒ job deploy **nằm chờ runner vô thời hạn** thay vì báo lỗi
(trước đây composite action báo ngay "cluster chưa dựng" — nhưng nó chạy *trên* runner). Một job nhỏ trên runner của
GitHub kiểm "cluster ACTIVE + project runner tồn tại" trước.

Nó không dùng role deployer: trust của deployer gắn với Environment, mà `production` có Required reviewers ⇒ phải
duyệt **2 lần** cho 1 lần deploy. Role preflight tin theo ref của tag (`rc-v*`, `v*`) và chỉ có `eks:DescribeCluster` +
`codebuild:BatchGetProjects` trên đúng 2 cluster / 2 project — không ECR, không access entry. ⚖️ Đổi lại: ai đẩy được
tag thì đọc được 2 thứ metadata đó; chấp nhận vì người đó vốn là collaborator của repo.

### 3. kubectl cài trong job, ghim bản + kiểm sha256

Image `aws/codebuild/standard:7.0` có sẵn git/jq/aws/curl nhưng kubectl của nó cũ hơn cluster nhiều bản. Job tải đúng
`v1.34.11` (bản node đang chạy) và kiểm sha256 — đây là binary cầm quyền deploy.

### 4. Prod: 1 NAT Gateway + 1 route table private **mỗi AZ** (`nat_gateway_per_az`)

Mất AZ chứa NAT duy nhất = mọi Pod ở 2 AZ còn lại mất đường ra SQS/EventBridge/STS/ECR dù vẫn "Running". Mỗi AZ một
NAT thì AZ nào chết, AZ đó tự chịu. Chỉ bật ở prod (+2 NAT ≈ +$0.12/giờ khi prod bật); dev/staging giữ 1 NAT.

## Hệ quả

- ✅ CLAUDE.md §10 "EKS public endpoint restricted ở prod" trở lại là quy tắc được tuân thủ, không còn là ngoại lệ.
- ✅ Prod không còn điểm chết đơn về mạng theo AZ.
- ⚠️ Thêm một phụ thuộc: GitHub App "AWS Connector for GitHub" + webhook. Runner hỏng (kết nối bị thu hồi, CodeBuild
  lỗi) thì CD staging/prod dừng — đường lui: deploy tay bằng đúng công cụ của CD (runbook `cd-dev.md` §5) từ máy có IP
  trong `public_access_cidrs`.
- ⚠️ IP nhà của người vận hành đổi thì `kubectl` từ laptop mất quyền vào — sửa `public_access_cidrs` rồi `apply`
  (vài phút). `scripts/platform-install.sh`, `e2e-flow.sh`, `chaos-az-outage.sh` đều chạy từ laptop.
- ⚠️ Job đầu tiên trên runner chậm hơn runner GitHub ~1 phút (CodeBuild cấp container + ENI trong VPC).
- 💰 CodeBuild `BUILD_GENERAL1_SMALL` tính theo phút; một lần deploy ~10 phút ≈ vài cent.

## Bằng chứng chạy thật

Ghi ở [runbook cd-runner](../runbooks/cd-runner.md) mục 5 sau lần release `rc-v2.3.0` → `v2.3.0`.

# ADR-013 — Runner CD trong VPC (CodeBuild) để khóa endpoint EKS; NAT mỗi AZ ở prod

- **Trạng thái:** **Rút lại một phần (2026-10-06).**
  - Quyết định 1–3 (runner CodeBuild trong VPC, job preflight, kubectl cài trong job): **đã rút lại, code đã gỡ** — tài
    khoản AWS này không được phép chạy build CodeBuild nào (quota = 0, xin tăng bị từ chối). Xem
    [Vì sao rút lại](#vì-sao-rút-lại-quyết-định-13-2026-10-06). Ngoại lệ "EKS endpoint `0.0.0.0/0` khi demo"
    (PROJECT.md §10, từ GĐ6) **có hiệu lực trở lại**.
  - Quyết định 4 (prod: 1 NAT mỗi AZ): **vẫn hiệu lực** — đóng rủi ro "1 NAT là điểm chết đơn"
    ([Lab 10](../labs/10-az-outage.md) §4).
- **Ngày:** 2026-10-05 (chấp nhận) → 2026-10-06 (rút lại quyết định 1–3)
- **Liên quan:** [ADR-005](ADR-005-nguon-su-that-phien-ban-cd.md) (CD), [ADR-006](ADR-006-staging-prod-ephemeral.md)
  (staging/prod ephemeral — nơi ghi ràng buộc endpoint ↔ runner), [ADR-002](ADR-002-mang-dev.md) (mạng).

> Phần "Bối cảnh" và "Quyết định" bên dưới giữ nguyên như lúc chấp nhận, để đọc lại được lý do và thiết kế. Bản cài đặt
> nằm trong lịch sử git: #220 (module `ci-runner`, workflow, role preflight) và #221 (chờ IAM có hiệu lực).

## Bối cảnh

PROJECT.md §10 yêu cầu endpoint public của EKS **giới hạn CIDR** ở prod. Từ GĐ6 quy tắc đó bị vi phạm có chủ đích:
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

## Vì sao rút lại quyết định 1–3 (2026-10-06)

Lần chạy thật đầu tiên (2026-10-05, dựng staging cho `rc-v2.3.0`):

| Bước | Kết quả |
|---|---|
| `terraform apply` state `shared` (kết nối `bss-github`, role preflight) + ủy quyền GitHub App | ✅ kết nối `AVAILABLE` |
| `terraform apply` staging với `public_access_cidrs = ["<IP người vận hành>/32"]` | ✅ sau khi sửa lỗi IAM chưa kịp có hiệu lực (#221): project + webhook tạo được |
| Job preflight của `cd-staging` (runner GitHub, role chỉ-đọc) | ✅ "cluster ACTIVE, runner sẵn sàng" |
| Job deploy xếp hàng với nhãn `codebuild-bss-staging-gha-runner-…` | ❌ không bao giờ có runner |

GitHub gửi webhook `workflow_job: queued` tới CodeBuild và nhận **HTTP 400**:

```
{"message":"Cannot have more than 0 builds in queue for the account"}
```

`aws service-quotas list-service-quotas --service-code codebuild`: mọi quota *Concurrently running builds for
<loại máy> environment* (Linux/Small, Medium, Large, ARM/Small, Lambda) của tài khoản đều là **0** — mặc định của AWS
là 1. Yêu cầu tăng `L-9D07B6EF` (Linux/Small) lên 1 gửi ngày 2026-10-06 đã **bị AWS từ chối** (cùng tài khoản từng bị
từ chối tăng quota vCPU EC2 ngày 2026-09-28 — ADR-006).

Phương án trong-VPC còn lại ở bảng trên cũng không dùng được với tài khoản này: EC2 self-hosted runner cần thêm ≥ 2 vCPU
trong khi prod đã dùng đủ 8/8 vCPU On-Demand.

**Quyết định:** gỡ toàn bộ phần runner (module `ci-runner`, kết nối CodeConnections + role preflight ở state `shared`,
job preflight, repository variable `AWS_PREFLIGHT_ROLE_ARN`); `cd-staging` / `cd-prod` chạy lại trên runner của GitHub
như tới `v2.2.0`, và staging/prod lại mở endpoint `0.0.0.0/0` **trong buổi demo ephemeral**
([runbook](../runbooks/cd-staging-prod-demo.md) §4). Không giữ code "để dành" sau một cờ bật/tắt: nó không chạy được
và không được kiểm thử ở đâu cả.

**Điều kiện xem lại:** tài khoản có quota CodeBuild ≥ 1 (hoặc chuyển sang tài khoản khác) → khôi phục từ #220 + #221.
Việc đã kiểm được trong lần thử và dùng lại được: Terraform tạo đúng project + webhook, job preflight chạy đúng; phần
chưa từng chạy: một job deploy thật trên runner trong VPC.

## Hệ quả (sau khi rút lại)

- ⚠️ PROJECT.md §10 "EKS public endpoint restricted ở prod" **vẫn là ngoại lệ có chủ đích** trong buổi demo: API server
  cần chữ ký IAM + EKS access entry, cluster chỉ sống vài giờ. Prod chạy thường trực thì phải giải quyết lại bài toán này.
- ✅ Prod không còn điểm chết đơn về mạng theo AZ (quyết định 4) — **đã đo 2026-10-06** ([Lab 10](../labs/10-az-outage.md)
  mục 3b, `INCLUDE_PUBLIC=1 scripts/chaos-az-outage.sh prod` trên `v2.3.0`): AZ `1a` chết cùng NAT của nó, Pod ở `1b`/`1c`
  vẫn mở được kết nối tới SQS/EventBridge/STS (207/208 lần trong 6 phút). +2 NAT ≈ +$0.12/giờ khi prod bật.
- 📝 Bài học vận hành: trước khi thiết kế dựa trên một dịch vụ AWS chưa từng dùng trong tài khoản, kiểm **quota đang áp
  dụng** của nó (`aws service-quotas list-service-quotas --service-code <dịch vụ>`) — tài khoản mới có thể bị đặt 0.

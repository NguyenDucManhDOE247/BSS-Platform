# Runbook — Runner CD trong VPC (CodeBuild) cho staging/prod

Thiết kế + lý do: [ADR-013](../adr/ADR-013-runner-cd-trong-vpc.md). Tóm tắt: job deploy của `cd-staging` / `cd-prod` chạy
trên một project CodeBuild gắn vào subnet private của môi trường và gọi API server qua endpoint **private**; endpoint
public của EKS chỉ còn mở cho IP của bạn.

```
GitHub (job chờ runner) ──webhook──▶ CodeBuild project bss-<env>-gha-runner ──ENI──▶ subnet private
                                                   │ (OIDC → role bss-github-deployer-<env>)
                                                   └──443──▶ API server EKS (endpoint private)
```

## 1. Làm một lần cho cả tài khoản (state `shared`)

```bash
make ENV=shared tf-plan     # thêm: kết nối bss-github (PENDING), role bss-github-cd-preflight
make ENV=shared tf-apply
```

**Ủy quyền GitHub — việc tay, một lần** (Terraform chỉ tạo được kết nối ở trạng thái `PENDING`):

1. AWS Console → **Developer Tools → Settings → Connections** (region `ap-southeast-1`) → `bss-github` →
   **Update pending connection**.
2. **Install a new app** → chọn tài khoản GitHub → *Only select repositories* → `BSS-Platform` → **Install**.
3. **Connect**. Kiểm: `terraform -chdir=infrastructure/terraform/environments/shared output github_connection_status`
   (sau `terraform refresh`) hoặc
   `aws codeconnections list-connections --query "Connections[?ConnectionName=='bss-github'].ConnectionStatus"` → `AVAILABLE`.

Rồi đặt repository variable cho job preflight:

```bash
./scripts/setup-github-environments.sh --apply     # thêm AWS_PREFLIGHT_ROLE_ARN (các variable cũ không đổi)
```

## 2. Mỗi lần dựng staging/prod

Không có bước riêng: `make ENV=<env> tf-apply` tạo luôn project + webhook (chỉ khi state `shared` đã có kết nối).
Trong `terraform.tfvars` của môi trường, đặt endpoint public về **IP của bạn**:

```hcl
public_access_cidrs = ["<IP công khai của bạn>/32"]    # curl -s https://checkip.amazonaws.com
```

Kiểm sau khi apply:

```bash
terraform -chdir=infrastructure/terraform/environments/<env> output ci_runner_project     # bss-<env>-gha-runner
aws eks describe-cluster --name bss-<env>-eks --query 'cluster.resourcesVpcConfig.[endpointPrivateAccess,publicAccessCidrs]'
```

## 3. Một lần deploy trông thế nào

1. Job **Cluster + runner trong VPC đã sẵn sàng?** (runner GitHub, role chỉ-đọc `bss-github-cd-preflight`) — đỏ ngay với
   thông báo rõ nếu cluster chưa dựng hoặc chưa có project runner.
2. Job deploy xếp hàng với nhãn `codebuild-bss-<env>-gha-runner-<run_id>-<attempt>` → CodeBuild khởi động 1 build
   (~1 phút) → build đó chính là runner; nó cài kubectl đúng bản rồi chạy các bước như trước.
3. Log của runner: CloudWatch `/aws/codebuild/bss-<env>-gha-runner`; log của job vẫn ở GitHub Actions như thường.

## 4. Sự cố thường gặp

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| `tf-apply` lỗi ở `aws_codebuild_webhook`: *connection … is not available / access denied* | Kết nối `bss-github` còn `PENDING`, hoặc GitHub App chưa được cấp repo này | Làm mục 1; rồi `apply` lại |
| Job deploy đứng ở "Waiting for a runner" quá 5 phút dù preflight xanh | Webhook không tới CodeBuild (app bị gỡ khỏi repo), hoặc project lỗi khi cấp ENI | CodeBuild → project → *Build history*: không có build nào = webhook; có build `FAILED` = xem log (thường là subnet hết IP hoặc thiếu quyền ENI) |
| Runner chạy nhưng `kubectl` treo ở "API server có với tới được không?" | Thiếu luật 443 từ security group của runner vào cluster security group | `terraform plan` phải sạch; kiểm `aws_vpc_security_group_ingress_rule.cluster_from_runner` |
| `kubectl` từ **laptop** bị từ chối/timeout sau khi đổi mạng | IP công khai của bạn đã đổi | Sửa `public_access_cidrs`, `tf-apply` (vài phút) |
| Preflight báo *Chưa có project CodeBuild …* | Môi trường dựng trước khi `shared` có kết nối → module không được tạo | `make ENV=<env> tf-apply` lại |
| Phải deploy khi runner hỏng | — | Deploy tay bằng đúng công cụ của CD từ laptop: [cd-dev.md §5](cd-dev.md) |

## 5. Bằng chứng chạy thật

_(điền sau lần release `rc-v2.3.0` → `v2.3.0`)_

# Runbook — Một buổi dựng staging/prod (ephemeral), chạy promotion, rồi destroy

Bối cảnh: [ADR-006](../adr/ADR-006-staging-prod-ephemeral.md) — staging/prod là **cluster riêng**
(đúng thiết kế gốc) nhưng **chỉ tồn tại trong một buổi làm việc**. Cách promote: [cd-promotion.md](cd-promotion.md).

> ⚠️ Mọi `terraform apply` ở đây tốn tiền thật. Luôn `plan` trước, đọc, rồi mới `apply`. Ước tính
> (chỉ để định hướng, số/ngày của CLAUDE.md §4 chia theo giờ — kiểm bằng Cost Explorer sau buổi đầu):
> staging ≈ $0.4/giờ, prod ≈ $1.3/giờ ⇒ một buổi 3 giờ cả hai ≈ $5. **Quên destroy ≈ $40/ngày.**

## 1. Điều kiện (làm một lần)

- `environments/shared` đã apply (3 role deployer, ECR) — [SETUP.md Part 6](../SETUP.md).
- 3 GitHub Environment + variable đã tạo (`scripts/setup-github-environments.sh --apply`).
- Đã có ít nhất một lần **CD dev xanh** cho commit muốn ship (image phải có trong ECR).
- Bạn đã chọn commit và biết số phiên bản (`rc-v0.1.0` / `v0.1.0`).

## 1b. ⚠️ Hạn mức vCPU EC2 — xin TRƯỚC buổi demo (lỗi thật gặp ngày 2026-09-25)

Tài khoản mới chỉ có **8 vCPU** "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z)". Mỗi `t3.large` = 2 vCPU, `t3.medium` = 2 vCPU:

| Môi trường | Node | vCPU |
|---|---|---|
| dev | 2 × t3.medium | 4 |
| staging | 3 × t3.large (2 node **không đủ**: 14 Pod × request 250–500m + hệ thống ≈ 3.6 vCPU/3.86) | 6 |
| prod | 4 × t3.large (3850m request app + hệ thống ≈ 1300m ≈ 5.15 vCPU; allocatable 7.72; chưa có autoscaler) | 8 |

Prod thất bại với `VcpuLimitExceeded` khi apply (cluster + RDS multi-AZ + NAT đã tạo, nhưng node group `CREATE_FAILED` — tốn ~$0.4/giờ cho tới khi destroy).
**Xin quota trước** (miễn phí, có thể thành support case và mất giờ–ngày):

```bash
aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-1216C47A --desired-value 32 --region ap-southeast-1
aws service-quotas list-requested-service-quota-change-history-by-quota --service-code ec2 --quota-code L-1216C47A --region ap-southeast-1 --query 'RequestedQuotas[].[Status,DesiredValue]'
```

Kiểm quota **đang có** (không phải quota đã xin) — prod cần **≥ 8** (4 node chạy = 8 vCPU; `system_node_max_size = 4`, đúng bằng quota mặc định — 2026-09-28 AWS đã từ chối tăng lên 32 nên prod được dimension vừa 8 vCPU; xem mục quota trong [ADR-006](../adr/ADR-006-staging-prod-ephemeral.md)):

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region ap-southeast-1 --query 'Quota.Value'
```

Khi chưa có quota: chạy **tuần tự** — destroy dev trước, staging (6 vCPU) xong thì destroy rồi mới dựng prod (không chạy được prod 10 vCPU với hạn mức 8).

**Ghi chú công cụ (Windows):** Helm trên Windows là v4 (bạn đã chốt giữ Helm v3.22 → dùng trong WSL). `scripts/platform-install.sh` chạy trong WSL cần `terraform output` (WSL không đọc được cache provider của Windows) và tải chart (trình tải của Helm trong WSL có lúc treo 120 s khi lấy `.tgz`). Từ 2026-10-05 script tự tải chart đã ghim phiên bản bằng `curl` có retry rồi cài từ file — không còn phải né tay.

## 1c. Checklist ngay trước khi dựng prod (release `v0.1.1`)

Làm theo thứ tự; mục nào không đạt thì **dừng, chưa `tf-apply`** (tf-apply prod là bước duy nhất tốn tiền lớn: RDS multi-AZ + NAT + EKS ≈ $1.3/giờ).

1. Quota vCPU **≥ 8** (lệnh ở §1b) **và không còn cluster nào khác đang chạy** (dev 4 + staging 6 + prod 8 > 8 ⇒ destroy dev/staging trước; chạy tuần tự).
2. `main` đã có PR "prod right-size requests" (prod 4 node, CPU requests backend 250m): `git log --oneline -5 origin/main`.
3. Tag rc của release (vd. `rc-v0.1.1`) còn trên remote và trỏ đúng commit đã qua staging: `git ls-remote --tags origin rc-v0.1.1`. (`rc-v0.1.0` là bản cũ, prod 500m — không dùng cho prod.)
4. Bản ghi rc đã `verified_in: [staging]`: `git fetch origin deploy-state && git show origin/deploy-state:releases/rc-v0.1.1.json | jq '.verified_in, .source.sha'`.
5. 7 image của bản rc vẫn còn trong ECR (lifecycle policy có thể xóa image cũ): digest tag `rc-v0.1.1` phải tồn tại cho cả 7 repo `bss/*`.
6. Không còn cluster nào đang chạy ngoài ý muốn: `aws eks list-clusters --region ap-southeast-1` (với quota 8: dev 4 + prod 8 = 12 > 8 ⇒ **phải destroy dev trước khi dựng prod**).
7. `terraform.tfvars` của prod: `ephemeral = true`; `public_access_cidrs` đúng lựa chọn A ở §4 (runner GitHub cần vào API server).
8. `make ENV=prod tf-plan` ⇒ kỳ vọng `Plan: 86 to add, 0 to change, 0 to destroy` (đo 2026-09-28), node group `desired = 4`.

Tag prod đặt trên **đúng commit của rc**, không phải HEAD của `main` (gate `gate-prod` so `source.sha`):

```bash
git tag v0.1.1 <sha-của-rc-v0.1.1> && git push origin v0.1.1     # → cd-prod: check ✓ → dừng chờ Approve
```

Prod dùng ~91–93% CPU requests trên 2 node (đo 2026-09-28) — không còn chỗ scale thêm; đừng dựng thêm workload lên prod trong buổi này.

Sau khi bấm **Approve** (Actions → run → Review deployments → `production`): xem job `deploy` tới smoke PASS, kiểm `kubectl -n bss get pods` (7 service × replicas, tất cả `Running`), rồi **destroy ngay** (§5). `releases/v0.1.1.json` được ghi trên nhánh `deploy-state` — đó là kết quả của buổi prod.

## 2. Dựng cluster (lặp lại cho `staging`, rồi `prod` nếu cần)

Thay `<env>` bằng `staging` hoặc `prod`.

```bash
cd infrastructure/terraform/environments/<env>
cp terraform.tfvars.example terraform.tfvars      # sửa owner_email, public_access_cidrs (xem §4), ephemeral = true
cd -

make ENV=<env> tf-init
make ENV=<env> tf-plan            # ĐỌC plan. staging và prod đều 86 tài nguyên (prod: RDS multi-AZ, 4 node)
make ENV=<env> tf-apply           # ~20–25 phút (EKS chiếm phần lớn)
make ENV=<env> kube-config
kubectl get nodes                 # 3 node t3.large (staging) / 4 node t3.large (prod) — Ready hết mới đi tiếp
```

Addon + namespace + database (lần nào dựng lại cũng phải làm — dữ liệu không được giữ, ADR-006):

```bash
./scripts/platform-install.sh <env>                 # namespace bss, ALB Controller, StorageClass, Secrets CSI
kubectl apply -k infrastructure/kubernetes/overlays/<env>/db-bootstrap
kubectl -n bss wait --for=condition=complete job/db-bootstrap --timeout=180s
kubectl -n bss logs job/db-bootstrap | tail -5      # "db-bootstrap: all 5 databases ready" (4 service + Keycloak)
kubectl delete -k infrastructure/kubernetes/overlays/<env>/db-bootstrap
```

## 3. Chạy promotion

```bash
git tag rc-v0.1.0 <commit> && git push origin rc-v0.1.0     # → cd-staging     (staging phải đang chạy)
# … QA … rồi
git tag v0.1.0 <cùng commit> && git push origin v0.1.0        # → cd-prod: check → Approve → deploy (prod phải đang chạy)
```

Cluster dựng **sau** khi đã có tag: chạy lại workflow bằng *Run workflow → Use workflow from: Tag* (không tag lại).
Kiểm ALB: `kubectl -n bss get ingress bss-ingress` → `ADDRESS`; `./scripts/smoke.sh <env>`.

Kiểm NetworkPolicy **được thi hành thật** (từ 2026-10-01 staging/prod bật `enable_network_policy` như dev —
`kubectl apply` policy luôn "thành công" kể cả khi CNI không chặn gì, nên phải đo bằng Pod thật):

```bash
kubectl -n kube-system get pods -l k8s-app=aws-node -o jsonpath='{.items[0].spec.containers[*].name}'   # phải có aws-eks-nodeagent
./scripts/netpol-matrix.sh "$(kubectl config current-context)"                                         # dev 12/12 (30/9); staging + prod 12/12 (1/10)
```

## 4. API endpoint của cluster ↔ runner của GitHub

**Vấn đề.** CLAUDE.md §10 yêu cầu EKS public endpoint **giới hạn CIDR** ở prod. Nhưng runner của GitHub
(`ubuntu-latest`) không có IP cố định (hàng nghìn dải, đổi liên tục; EKS chỉ nhận tối đa 40 CIDR) — nên nếu
`public_access_cidrs = ["<IP nhà bạn>"]` thì `kubectl` chạy trong Actions **timeout** ở bước
`Preflight`/`Render + apply`.

| Lựa chọn | Đánh đổi |
|---|---|
| **A. `["0.0.0.0/0"]` trong lúc buổi demo** (khuyến nghị cho ephemeral) | API server vẫn cần chữ ký IAM + RBAC (không ẩn danh), và cluster tồn tại vài giờ. Nhưng mở cho cả Internet thăm dò/brute-force và **vi phạm chữ nghĩa** của quy tắc §10 — chấp nhận được **chỉ vì** prod ở đây là ephemeral; ghi rõ trong đề tài |
| B. Runner trong VPC + endpoint private | Đúng chuẩn production. **Đã thử 2026-10-05 bằng CodeBuild và phải rút lại**: tài khoản này có quota CodeBuild = 0 và AWS từ chối tăng ([ADR-013](../adr/ADR-013-runner-cd-trong-vpc.md)); EC2 self-hosted runner thì không còn vCPU (prod dùng 8/8). Làm lại khi có quota |
| C. Không để CD chạm cluster; deploy bằng tay từ máy bạn (CIDR = IP nhà) với đúng công cụ của CD | Giữ endpoint chặt, nhưng mất tự động hoá + cổng duyệt của GitHub cho bước deploy. Lệnh: [cd-dev.md §5](cd-dev.md) |
| D. Thêm/bớt IP runner lúc chạy bằng `aws eks update-cluster-config` | Quyền `UpdateClusterConfig` rất rộng cho role CI, mỗi lần cập nhật mất vài phút, dễ để sót — không khuyến nghị |

Mặc định trong `terraform.tfvars.example` là **danh sách chặt**; bạn tự đổi sang `0.0.0.0/0` khi chọn A, và
**quay lại danh sách chặt/destroy** khi xong. Quyết định này là của bạn — đây là ngoại lệ có chủ đích của
§10, không phải mặc định mới.

## 5. Kết thúc buổi (KHÔNG BỎ QUA)

```bash
make ENV=prod    tf-destroy       # gõ 'destroy-prod' để xác nhận; script tự xóa Ingress trước (ALB không nằm trong state)
make ENV=staging tf-destroy
```

Kiểm tài nguyên mồ côi (mỗi lệnh phải ra rỗng — cũng được in cuối `teardown.sh`):

```bash
aws elbv2 describe-load-balancers   --region ap-southeast-1 --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-nat-gateways        --region ap-southeast-1 --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws ec2 describe-volumes             --region ap-southeast-1 --filters Name=status,Values=available --query 'Volumes[].VolumeId'
aws rds describe-db-instances        --region ap-southeast-1 --query 'DBInstances[].DBInstanceIdentifier'
aws eks list-clusters                --region ap-southeast-1
```

`shared` (ECR, role, OIDC) và nhánh `deploy-state` **không** bị destroy — đó là trạng thái bền của ADR-006.
Hôm sau xem chi phí: Cost Explorer → lọc tag `Environment` = `staging`/`prod`.

## 6. Sự cố thường gặp

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| `terraform destroy` treo/lỗi `DependencyViolation` ở VPC | ALB/ENI mồ côi (Ingress chưa được xóa trước) | `kubectl -n bss delete ingress --all`, đợi ALB biến mất (`aws elbv2 …`), chạy lại destroy |
| `apply` lần sau lỗi `InvalidRequestException: secret … scheduled for deletion` | Lần trước destroy với `ephemeral = false` → tên secret bị giữ 30 ngày | `aws secretsmanager delete-secret --secret-id <tên> --force-delete-without-recovery` rồi apply; từ nay `ephemeral = true` |
| `destroy` báo `Cannot delete protected DB instance` | Dựng với `ephemeral = false` | Đặt `ephemeral = true`, `terraform apply` (chỉ tắt bảo vệ), rồi destroy |
| Actions: `kubectl` timeout ở Preflight | `public_access_cidrs` chặn IP runner (§4) | Chọn A/B/C ở §4 |
| Pod `CreateContainerConfigError` (secret `*-db-credentials` không có) | Chưa chạy `db-bootstrap`, hoặc SPC/IRSA sai | `kubectl -n bss describe pod`; xem [ADR-004](../adr/ADR-004-db-credential-wiring-dev.md) |
| Pod `keycloak` `CreateContainerConfigError` (secret `keycloak-db`/`keycloak-admin` không có) | Cùng nguyên nhân: CSI chưa sync — SPC `keycloak-credentials` hoặc IRSA `bss-<env>-keycloak` sai; hoặc chưa chạy `db-bootstrap` (database `keycloak`) | `kubectl -n bss describe pod -l app=keycloak`; [ADR-008 quyết định 8](../adr/ADR-008-danh-tinh-va-quyen-so-huu.md) |
| Smoke: `không lấy được token (Keycloak chưa sẵn sàng?)` | Keycloak khởi động lần đầu chậm (tạo schema trên RDS, ~1–3 phút) hoặc crash | `kubectl -n bss logs deploy/keycloak`; smoke tự chờ `rollout status deployment/keycloak` |
| `apply` prod: node group `CREATE_FAILED`, `VcpuLimitExceeded` | Quota vCPU EC2 (mặc định 8) < vCPU đang chạy + 8 cần cho 4 × t3.large (thường do dev/staging còn chạy). Cluster + RDS + NAT đã tạo nên đang **tốn tiền** | `make ENV=prod tf-destroy` ngay; destroy môi trường khác đang chạy (hoặc xin quota, §1b), rồi dựng lại. Đừng để cluster dở dang qua đêm |
| Pod `Pending` "Insufficient cpu" dù node `Ready` | Tổng `requests` > allocatable (t3.large ≈ 1.93 vCPU/node); chưa có autoscaler nên không tự thêm node | Xem mục "Allocated resources" của `kubectl describe node`; thêm node (nâng `desired_size` trong quota cho phép) — không nới `requests` để "lách" |
| `apply`: `ResourceAlreadyExistsException: The specified log group already exists` | Còn log group `/aws/eks/bss-<env>-eks/cluster` hoặc `/aws/rds/instance/bss-<env>-pg/postgresql` từ lần dựng trước — do AWS tự tạo (trước 2026-10-06 Terraform chưa quản lý) hoặc tạo lại sau destroy | `python tools/ops/orphan_finder.py` liệt kê; xóa đúng log group trong thông báo lỗi (`aws logs delete-log-group --log-group-name <tên>`) rồi `apply` lại — phần đã tạo không mất |
| `namespaces "bss" not found` | Chưa `platform-install.sh` | Chạy nó (bước 2) |

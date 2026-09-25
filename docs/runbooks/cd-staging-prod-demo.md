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

## 2. Dựng cluster (lặp lại cho `staging`, rồi `prod` nếu cần)

Thay `<env>` bằng `staging` hoặc `prod`.

```bash
cd infrastructure/terraform/environments/<env>
cp terraform.tfvars.example terraform.tfvars      # sửa owner_email, public_access_cidrs (xem §4), ephemeral = true
cd -

make ENV=<env> tf-init
make ENV=<env> tf-plan            # ĐỌC plan. staging ≈ 60–70 tài nguyên; prod tương tự + RDS multi-AZ
make ENV=<env> tf-apply           # ~20–25 phút (EKS chiếm phần lớn)
make ENV=<env> kube-config
kubectl get nodes                 # 2 node (staging: t3.large) / 3 node (prod)
```

Addon + namespace + database (lần nào dựng lại cũng phải làm — dữ liệu không được giữ, ADR-006):

```bash
./scripts/platform-install.sh <env>                 # namespace bss, ALB Controller, StorageClass, Secrets CSI
kubectl apply -k infrastructure/kubernetes/overlays/<env>/db-bootstrap
kubectl -n bss wait --for=condition=complete job/db-bootstrap --timeout=180s
kubectl -n bss logs job/db-bootstrap | tail -5      # "db-bootstrap: all 4 databases ready"
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

## 4. API endpoint của cluster ↔ runner của GitHub

**Vấn đề.** CLAUDE.md §10 yêu cầu EKS public endpoint **giới hạn CIDR** ở prod. Nhưng runner của GitHub
(`ubuntu-latest`) không có IP cố định (hàng nghìn dải, đổi liên tục; EKS chỉ nhận tối đa 40 CIDR) — nên nếu
`public_access_cidrs = ["<IP nhà bạn>"]` thì `kubectl` chạy trong Actions **timeout** ở bước
`Preflight`/`Render + apply`.

| Lựa chọn | Đánh đổi |
|---|---|
| **A. `["0.0.0.0/0"]` trong lúc buổi demo** (khuyến nghị cho ephemeral) | API server vẫn cần chữ ký IAM + RBAC (không ẩn danh), và cluster tồn tại vài giờ. Nhưng mở cho cả Internet thăm dò/brute-force và **vi phạm chữ nghĩa** của quy tắc §10 — chấp nhận được **chỉ vì** prod ở đây là ephemeral; ghi rõ trong đề tài |
| B. Self-hosted runner trong VPC + endpoint private | Đúng chuẩn production; tốn thêm EC2 + vận hành runner (cập nhật, bảo mật) — hợp lý khi prod chạy thật |
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
| `namespaces "bss" not found` | Chưa `platform-install.sh` | Chạy nó (bước 2) |

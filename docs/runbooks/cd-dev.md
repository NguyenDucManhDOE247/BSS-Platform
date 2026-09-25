# Runbook — CD dev (merge vào `main` → dev tự cập nhật)

Thiết kế và lý do: [ADR-005](../adr/ADR-005-nguon-su-that-phien-ban-cd.md). Đọc trước nếu chưa biết
"desired", "manifest", "`deploy-state`" nghĩa là gì.

## 1. Chuyện gì xảy ra khi bạn merge một PR

```
push main ─► plan ─────────────► build (matrix) ────────► deploy
             │ desired từ git     │ chỉ service THIẾU        │ áp manifest ĐẦY ĐỦ 7 service
             │ image nào chưa có  │ image trong ECR          │ chờ rollout · kiểm drift · smoke
             │ ECR? cluster sống? │ tag = commit cuối chạm   │ hỏng → rollback về dev.json cũ
             └────────────────────┘ thư mục service          │ PASS → ghi dev.json (deploy-state)
```

- Trigger: `push` lên `main` đụng `apps/**`, `infrastructure/kubernetes/**`, hoặc chính các file CD;
  hoặc chạy tay (`workflow_dispatch`) để **đồng bộ dev về HEAD của `main`**.
- Xếp hàng, không hủy (`concurrency: cd-dev`, `cancel-in-progress: false`).

## 2. Điều kiện tiên quyết (làm một lần)

| Việc | Cách kiểm tra |
|---|---|
| `terraform apply` `shared` (role `bss-github-deployer-dev`) rồi `dev` (access entry) | `terraform output` ở `environments/shared` |
| GitHub Environment `dev` có variable `AWS_ROLE_ARN` | `gh api repos/{owner}/{repo}/environments/dev/variables` |
| Repository variable `ECR_REGISTRY` | `gh variable list` |
| Cluster có namespace `bss` + addon (chạy **bằng admin**, không phải bằng CD) | `./scripts/platform-install.sh dev` |
| Đã chạy `db-bootstrap` Job (4 DB + 4 user) | `overlays/dev/db-bootstrap/README.md` |

Lệnh cụ thể để tạo Environment/variable: [SETUP.md Part 6](../SETUP.md).

## 3. Chu trình hằng ngày (dev bị destroy mỗi tối)

- **Tối:** `make ENV=dev tf-destroy` (nhớ xóa Ingress trước — ALB không nằm trong state Terraform).
  Nếu tối đó có merge vào `main`: `plan` thấy cluster không tồn tại → chỉ **build + push image**, bỏ qua
  deploy, run vẫn **xanh** kèm `::notice::` (không phải lỗi).
- **Sáng:** `terraform apply` → `./scripts/platform-install.sh dev` → db-bootstrap → chạy
  **Actions → CD — dev → Run workflow** trên `main`. Workflow tính lại desired từ git và áp cả 7
  service. (`dev.json` cũ không cần để deploy — nó chỉ để **rollback** và để biết lần trước chạy gì.)

## 4. Xem hệ thống đang chạy gì / lịch sử deploy

```bash
git fetch origin deploy-state
git show origin/deploy-state:dev.json | jq '.source.sha, .services'        # bản tốt gần nhất
git log origin/deploy-state --format='%h %ad %s' --date=short -- dev.json   # lịch sử deploy
./scripts/release-manifest.sh new dev HEAD | jq .services                   # desired của HEAD (để so sánh)
kubectl -n bss get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

## 5. Triển khai/rollback THỦ CÔNG bằng đúng cơ chế của CD

Dùng khi Actions hỏng hoặc cần quay về một bản cụ thể. Cần `aws`, `kubectl`, `jq`, đã `make ENV=dev kube-config`.

```bash
REG=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.ap-southeast-1.amazonaws.com

# (a) áp một manifest có sẵn trong lịch sử deploy-state (vd. bản trước đó)
git fetch origin deploy-state
git show origin/deploy-state~1:dev.json > /tmp/dev-prev.json
./scripts/release-manifest.sh validate /tmp/dev-prev.json
kubectl apply -k "$(./scripts/release-manifest.sh render /tmp/dev-prev.json dev "$REG")"
kubectl -n bss get deployments -o json | ./scripts/release-manifest.sh verify-cluster /tmp/dev-prev.json "$REG"
./scripts/smoke.sh dev

# (b) hoặc áp desired của một commit bất kỳ (cần clone đầy đủ, không --depth)
./scripts/release-manifest.sh new dev <commit> > /tmp/dev-x.json
./scripts/release-manifest.sh ecr-missing /tmp/dev-x.json                  # phải ra []
```

⚠️ Áp tay **không** cập nhật `dev.json`. Muốn ghi lại:
`./scripts/release-manifest.sh state-put "manual: ..." dev.json=/tmp/dev-x.json`.

## 6. Sự cố thường gặp

| Triệu chứng | Nguyên nhân thường gặp | Xử lý |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy của role không khớp `sub` của job. Job có `environment: dev` ⇒ `sub` = `repo:<owner>/<repo>:environment:dev` (KHÔNG còn `ref:refs/heads/main`) | Xem `sub` thật trong log bước configure-aws-credentials; đối chiếu `aws_iam_role.deployer_dev` ở `environments/shared` |
| Preflight: `KHÔNG có quyền create … trong namespace bss` | Chưa có access entry/policy cho role này trên cluster (cluster mới dựng lại, hoặc chưa `terraform apply dev` sau khi đổi role) | `terraform apply` ở `environments/dev`; kiểm `aws eks list-associated-access-policies --cluster-name bss-dev-eks --principal-arn <role>` |
| Preflight lỗi ở `secretproviderclasses…` nhưng các loại khác đạt | `AmazonEKSEditPolicy` không phủ CRD của Secrets Store CSI | Đổi policy của deployer thành `AmazonEKSClusterAdminPolicy` **vẫn scope namespace `bss`** (`aws_eks_access_policy_association`) |
| `namespaces "bss" not found` khi apply | Cluster mới, chưa chạy `platform-install.sh` (nó mới là nơi tạo namespace) | `./scripts/platform-install.sh dev` |
| `state-get thất bại` / `could not read Username` | Job thiếu `contents: write` hoặc checkout không giữ credential | Job `deploy` phải có `permissions: contents: write`; `actions/checkout` để mặc định `persist-credentials` |
| `repo là clone nông` | Thiếu `fetch-depth: 0` ở bước checkout | Thêm `with: fetch-depth: 0` |
| Build lỗi `secret github_token: not found` (customer-service) | Thiếu `--secret` hoặc `packages: read` | Đã có trong `cd-dev.yml`; nếu build tay thì `GITHUB_TOKEN=<PAT read:packages>` |
| `DRIFT customer-service: cluster=…:dev manifest=…:<sha>` | Overlay có `newName` khác registry truyền vào `render` ⇒ chồng `images:` không khớp tên | `ECR_REGISTRY` phải đúng bằng registry trong `newName` của overlay |
| Smoke: `Ingress vẫn chưa có hostname` | ALB Controller chưa cài/lỗi IAM, hoặc Ingress bị từ chối (vd. HTTPS không cert — B-23) | `kubectl -n bss describe ingress bss-ingress`; `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| Run xanh nhưng dev không đổi gì | Cluster đang tắt (`::notice::` ở job plan) | Dựng cluster rồi chạy `workflow_dispatch` |
| Rollback chạy nhưng workflow vẫn đỏ | **Đúng thiết kế**: rollback thành công không được che sự cố của bản mới | Xem log job, sửa bản mới, merge lại |

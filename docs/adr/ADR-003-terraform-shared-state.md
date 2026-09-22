# ADR-003 — Tách `environments/shared` khỏi state riêng từng môi trường

- **Trạng thái:** Chấp nhận (Accepted)
- **Ngày:** 2026-09-22
- **Giai đoạn:** 4 — Terraform + bootstrap AWS

## Bối cảnh

**B-33**: module `ecr` (`name_prefix = "bss"`, không phụ thuộc `local.env`) được gọi ở **cả 3**
`environments/{dev,staging,prod}/main.tf`. Vì cả 3 dùng cùng tên repo (`bss/customer-service`...),
3 state riêng biệt cùng "sở hữu" (theo nghĩa Terraform: `terraform apply` ở mỗi state sẽ cố tạo
resource này) **một** tài nguyên AWS thật duy nhất:

- `terraform apply` ở env thứ 2 (sau khi env đầu đã tạo repo) báo lỗi `RepositoryAlreadyExists`.
- `terraform destroy` ở dev (chạy **mỗi tối** để tiết kiệm chi phí — CLAUDE.md §10) sẽ xóa
  ECR repo mà staging/prod đang dùng để pull image.
- Tương tự với GitHub OIDC provider + deployer role (`enable_github_oidc = true` chỉ ở dev,
  `module "iam"`): vai trò CI/CD duy nhất của **cả 3** môi trường nằm trong state hay bị xóa
  nhất.

Nguyên nhân gốc: state Terraform hiện tại **1 thư mục = 1 môi trường**, nhưng ECR/GitHub OIDC
không phải tài nguyên "của" một môi trường — chúng là tài nguyên **cấp tài khoản AWS**, sống lâu
hơn vòng đời của bất kỳ dev/staging/prod nào.

## Quyết định

Nguyên tắc: **tài nguyên sống lâu hơn một môi trường thì không nằm trong state của môi trường
đó.** Tạo `environments/shared/` — một "môi trường" thứ 4, riêng, apply **trước** dev/staging/prod:

- `module "ecr"` chuyển vào đây, gọi đúng 1 lần.
- GitHub OIDC provider (`aws_iam_openid_connect_provider`) chuyển vào đây — AWS chỉ cho phép
  **một** provider `token.actions.githubusercontent.com` mỗi account, tạo lần 2 sẽ lỗi, nên bản
  chất nó vốn đã luôn là tài nguyên "shared", chỉ là bị đặt sai chỗ.
- **B-34**: tách deployer role thành **2 role** thay vì 1 (`bss-github-deployer-nonprod` cho
  dev+staging, `bss-github-deployer-prod` cho prod riêng) — giảm blast radius: một lỗi cấu hình ở
  workflow chạm tới dev/staging không thể tự động có quyền trên prod. Trust policy cũng thu hẹp
  từ `repo:<repo>:*` (mọi nhánh/tag/PR) xuống còn đúng những `sub` mà từng workflow thật sự dùng
  (`ref:refs/heads/main`, `ref:refs/tags/rc-v*`, `pull_request` cho nonprod;
  `ref:refs/tags/v*` cho prod).
- `dev`/`staging`/`prod` đọc output của `shared` qua `data "terraform_remote_state"` — **không**
  truyền qua biến `.tfvars` — vì giá trị (ARN, registry id...) là do Terraform *tạo ra*, không
  phải do người vận hành *chọn*; dùng remote state giữ đúng nguyên tắc "một nguồn sự thật".
- **B-34 tiếp**: thêm `aws_eks_access_entry` + `aws_eks_access_policy_association` (namespace
  `bss`, policy `AmazonEKSEditPolicy`) cho role deployer tương ứng **trong từng state môi
  trường** (không phải trong `shared`) — vì access entry gắn với một cluster EKS cụ thể, dữ liệu
  đó (`cluster_name`) chỉ state của môi trường đó biết.

## Thứ tự apply (quan trọng — không đổi được)

```
shared  →  dev  →  (staging, prod tùy nhu cầu)
```

`dev`/`staging`/`prod` sẽ báo lỗi ngay ở bước `plan` nếu `shared` chưa được apply lần nào (chưa
có `shared/terraform.tfstate` để đọc).

## Hệ quả

- ✅ `terraform destroy` dev không còn kéo theo xóa nhầm tài nguyên staging/prod đang dùng.
- ✅ Apply 3 môi trường song song (khi cần) không còn tranh chấp tạo cùng 1 ECR repo.
- ✅ Prod có role CI/CD triển khai **riêng**, không lẫn với dev/staging — đúng nguyên tắc least
  privilege / giảm blast radius của CLAUDE.md §10.
- ⚠️ Thêm một bước thủ công: phải nhớ `apply shared` trước, và nhớ **không** `terraform destroy`
  `shared` theo lịch "destroy mỗi tối" (chỉ `dev` mới destroy hằng đêm — `shared`, `staging`,
  `prod` không nằm trong lịch đó).
- ⚠️ `data "terraform_remote_state"` đọc trực tiếp **toàn bộ** state file của `shared` (không chỉ
  phần `output`) — chấp nhận được vì đây cùng một account/chủ sở hữu, nhưng là lý do state luôn
  phải mã hóa (`encrypt = true`, đã có sẵn) và bucket phải chặn public access.

## Lựa chọn khác đã cân nhắc

1. **Terraform Workspace thay vì thư mục riêng cho `shared`** — không chọn, giữ nhất quán với
   quyết định "thư mục riêng cho mỗi môi trường" đã có từ đầu dự án (xem `learning/14` mục 1).
2. **Giữ ECR/GitHub OIDC trong `dev`, các env khác đọc qua `terraform_remote_state` tới state của
   `dev`** — về mặt kỹ thuật cũng giải quyết được B-33, nhưng đặt sai ngữ nghĩa: `dev` vẫn là môi
   trường bị destroy mỗi tối, người đọc code sẽ hiểu nhầm "dev" là nguồn sự thật cho tài nguyên
   dùng chung. Một thư mục `shared` riêng, không bao giờ destroy, thể hiện đúng vòng đời tài
   nguyên hơn.

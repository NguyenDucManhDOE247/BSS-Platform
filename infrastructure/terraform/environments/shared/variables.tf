variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "owner_email" {
  type        = string
  description = "Tag added to every resource for billing accountability"
}

variable "github_repos" {
  type        = list(string)
  description = "e.g. ['NguyenDucManhDOE247/BSS-Platform'] — repos allowed to assume the deployer roles"
  default     = []
}

variable "github_extra_sub_prefixes" {
  type        = list(string)
  description = <<-EOT
    Extra `sub` claim prefixes the deployer roles trust, IN ADDITION to "repo:<github_repos entry>".
    Needed when the repository uses GitHub's *immutable subject* claims (the default for newer
    repos): the JWT's `sub` is then "repo:OWNER@<owner-id>/REPO@<repo-id>:environment:<env>" and the
    plain-name form never matches (found for real on the first cd-dev run: "Not authorized to
    perform sts:AssumeRoleWithWebIdentity"). Read it from GitHub, don't guess:
      gh api repos/OWNER/REPO/actions/oidc/customization/sub --jq .sub_claim_prefix
    Only exact prefixes go here (no wildcards) — the trust condition is StringEquals.
  EOT
  default     = []
}

# ── Tên miền (B-23, ADR-012) — xem dns.tf ──
variable "domain_name" {
  type        = string
  default     = "bssplatform.dpdns.org"
  description = "Tên miền công khai (đăng ký ở DigitalPlat, NS trỏ về Route 53). \"\" = không tạo zone/cert (fork chưa có miền)."
}

variable "dns_delegated" {
  type        = bool
  default     = false
  description = "true SAU KHI đã nhập NS của zone vào nhà đăng ký và `dig NS` thấy awsdns-* — khi đó Terraform mới chờ ACM cấp cert."
}
variable "name_prefix" { type = string }

variable "cluster_oidc_provider_arn" {
  type        = string
  description = "OIDC provider ARN from the EKS module"
}

variable "cluster_oidc_provider_url" {
  type        = string
  description = "OIDC provider URL (no scheme) from the EKS module"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ── Karpenter (ADR-010) — chỉ dev bật ──
variable "enable_karpenter" {
  type        = bool
  default     = false
  description = "Tạo IAM role controller + hàng đợi interruption cho Karpenter (karpenter.tf)"
}

variable "cluster_name" {
  type        = string
  default     = ""
  description = "Tên cluster EKS — Karpenter scope quyền EC2 theo tag kubernetes.io/cluster/<name>"
}

variable "node_role_arn" {
  type        = string
  default     = ""
  description = "Role của node (modules/eks) — Karpenter được iam:PassRole đúng role này"
}

# ── ExternalDNS (B-23, ADR-012) — external-dns.tf ──
variable "external_dns_zone_id" {
  type        = string
  default     = null
  description = "Route 53 zone (state shared). null = không tạo role ExternalDNS"
}

variable "external_dns_hostnames" {
  type        = list(string)
  default     = []
  description = "Tên miền cluster này được ghi (vd. [\"dev.bssplatform.dpdns.org\"]) — kèm 3 bản ghi TXT `extdns-{a,aaaa,cname}.<tên>` của registry"
}
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

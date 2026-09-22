variable "name_prefix" { type = string }

variable "cluster_oidc_provider_arn" {
  type        = string
  description = "OIDC provider ARN from the EKS module"
}

variable "cluster_oidc_provider_url" {
  type        = string
  description = "OIDC provider URL (no scheme) from the EKS module"
}

variable "services" {
  description = "Map of service_name => { namespace, service_account, inline_policy_statements, managed_policy_arns }"
  type = map(object({
    namespace                = string
    service_account          = string
    inline_policy_statements = list(any)
    managed_policy_arns      = list(string)
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}

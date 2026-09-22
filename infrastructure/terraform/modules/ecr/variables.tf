variable "name_prefix" { type = string }

variable "service_names" {
  type        = list(string)
  description = "List of service names (one repository per service)"
  default = [
    "customer-service",
    "product-catalog",
    "order-management",
    "billing-service",
    "api-gateway",
    "web-portal",
    "admin-console",
  ]
}

variable "force_delete" {
  type        = bool
  default     = false
  description = <<-EOT
    B-37 note: the original ask was "force_delete for dev" so `terraform destroy` on dev's
    nightly cycle doesn't fail when a repo still has images. Since B-33 (ADR-003), ECR lives in
    environments/shared, which is NOT destroyed nightly (dev is) — so there is no longer a "dev"
    call site for this. Left as an explicit opt-in (default false) rather than removed: a repo
    with images deleted out from under it is exactly the kind of surprise `force_delete=true`
    should require you to type, not something a default should do for you.
  EOT
}

variable "tags" {
  type    = map(string)
  default = {}
}

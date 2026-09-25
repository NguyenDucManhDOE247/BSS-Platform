variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "owner_email" {
  type = string
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the EKS public endpoint. MUST be restricted in staging — no default on purpose (see terraform.tfvars.example), so `terraform plan` fails loudly instead of silently defaulting to 0.0.0.0/0 like it used to."
}

variable "ephemeral" {
  type        = bool
  default     = false
  description = <<-EOT
    ADR-006: staging/prod are built for a working session and destroyed afterwards. `true` makes the
    environment destroyable: RDS `deletion_protection = false` (modules/rds then also skips the final
    snapshot) and Secrets Manager `recovery_window_in_days = 0` (otherwise the secret NAMES stay
    reserved for the recovery window and the next `apply` fails on a name collision — B-37).
    `false` (default, safe) keeps deletion protection ON and a 30-day secret recovery window — use it
    for any environment whose data you would miss. For a demo, set `ephemeral = true` in terraform.tfvars.
  EOT
}

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "eks_node_security_group_id" { type = string }

variable "engine_version" {
  type    = string
  default = "15.5"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "initial_database_name" {
  type    = string
  default = "bss"
}

variable "master_username" {
  type    = string
  default = "bssadmin"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "backup_retention_days" {
  type    = number
  default = 1
}

variable "performance_insights_enabled" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "secret_recovery_window_days" {
  type        = number
  default     = 30
  description = "Secrets Manager recovery window for the master + per-service DB credential secrets (B-21, B-37). Set to 0 for an environment that gets `terraform destroy`'d and re-applied often (dev) — otherwise the next apply fails because the secret NAME is still reserved during its recovery window. (Also applied to modules/rds's master secret in a separate PR — see B-37.)"
}

variable "tags" {
  type    = map(string)
  default = {}
}

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

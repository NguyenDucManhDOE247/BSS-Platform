variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "owner_email" {
  type = string
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "MUST be restricted in prod (e.g. office IPs + bastion). Never 0.0.0.0/0."
}

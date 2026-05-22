variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "owner_email" {
  type        = string
  description = "Tag added to every resource for billing accountability"
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the EKS public endpoint. Use your home/office IP."
  default     = ["0.0.0.0/0"]
}

variable "github_repos" {
  type        = list(string)
  description = "e.g. ['ngocta/bss-platform']"
  default     = []
}

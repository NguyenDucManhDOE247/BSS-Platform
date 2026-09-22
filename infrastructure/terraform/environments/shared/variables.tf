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

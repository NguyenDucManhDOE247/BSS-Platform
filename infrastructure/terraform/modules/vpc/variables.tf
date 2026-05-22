variable "name_prefix" {
  type        = string
  description = "Prefix for resource names, e.g. 'bss-dev'"
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type        = number
  default     = 2
  description = "Number of AZs to span (2 is the minimum for EKS HA)"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (used for subnet discovery tags)"
}

variable "enable_nat_gateway" {
  type        = bool
  default     = false
  description = "NAT Gateway costs ~$1.10/day. Keep false for dev; true for prod."
}

variable "enable_vpc_endpoints" {
  type        = bool
  default     = true
  description = "Cheap alternative to NAT for AWS service calls (ECR, S3, Secrets)."
}

variable "tags" {
  type    = map(string)
  default = {}
}

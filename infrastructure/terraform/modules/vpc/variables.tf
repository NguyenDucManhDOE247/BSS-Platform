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
  description = "NAT Gateway costs ~$1.10/day. See docs/adr/ADR-002-mang-dev.md for why dev also enables this (private nodes need outbound internet for Helm chart images — VPC endpoints alone don't cover it)."
}

variable "nat_gateway_per_az" {
  type        = bool
  default     = false
  description = "true = 1 NAT Gateway + 1 route table private cho MỖI AZ (không còn điểm chết đơn khi mất 1 AZ — Lab 10 §4). +~$1.4/ngày mỗi NAT thêm; chỉ bật ở prod. Chỉ có tác dụng khi enable_nat_gateway = true."
}

variable "enable_interface_endpoints" {
  type        = bool
  default     = false
  description = <<-EOT
    Interface (PrivateLink) endpoints for ecr.api/ecr.dkr/secretsmanager/logs/sts — ~$0.013/h
    PER endpoint PER AZ. Only worth it if you're deliberately avoiding a NAT Gateway (a fully
    private cluster with no outbound internet at all, e.g. compliance-driven). This repo doesn't
    do that (see ADR-002) — private-cluster mode also needs an ECR mirror for every Helm chart
    image, which the interface endpoints alone don't solve. The S3 gateway endpoint below is
    ALWAYS created regardless of this flag: it's free and has no AZ multiplier.
  EOT
}

variable "tags" {
  type    = map(string)
  default = {}
}

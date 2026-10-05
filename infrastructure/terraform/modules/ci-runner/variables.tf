variable "name_prefix" {
  type        = string
  description = "vd. bss-staging → project bss-staging-gha-runner"
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Subnet private (có đường ra NAT): runner phải tới được GitHub."
}

variable "cluster_security_group_id" {
  type        = string
  description = "Cluster security group của EKS — nhận 443 từ runner."
}

variable "github_repo" {
  type        = string
  description = "owner/repo mà runner phục vụ."
}

variable "github_connection_arn" {
  type        = string
  description = "ARN kết nối CodeConnections tới GitHub (state shared). Phải AVAILABLE (đã bấm ủy quyền trong console) thì webhook mới tạo được."
}

variable "image" {
  type        = string
  default     = "aws/codebuild/standard:7.0"
  description = "Image của runner (Ubuntu 22.04: git, jq, aws-cli v2, curl). kubectl đúng bản do workflow tự cài."
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}

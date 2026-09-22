variable "name_prefix" {
  type        = string
  description = "e.g. 'bss-dev'"
}

variable "cluster_name" {
  type = string
}

variable "k8s_version" {
  type    = string
  default = "1.34" # B-36: 1.30 (May 2024) is long out of standard support — extended support
  # bills the control plane at $0.60/h instead of $0.10/h (6x). Verify what's CURRENTLY in
  # standard support before relying on this default:
  #   aws eks describe-cluster-versions --query "clusterVersions[?versionStatus=='STANDARD_SUPPORT'].clusterVersion"
}

variable "cluster_log_types" {
  type        = list(string)
  default     = ["api", "audit"]
  description = <<-EOT
    B-39: EKS bills per GB ingested per enabled control-plane log type, same as any other
    CloudWatch Logs source. The full set is ["api", "audit", "authenticator", "controllerManager",
    "scheduler"] — useful for prod (audit trail across everything), overkill for a dev cluster
    that gets destroyed nightly. "api" (every API server request) + "audit" (who-did-what, for
    RBAC/security review) cover the two log types you'd actually go looking for after an
    incident; controllerManager/scheduler logs are mostly only useful while debugging the
    scheduler/controllers themselves.
  EOT
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "public_access_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "Restrict to your office/home IP in production"
}

variable "system_node_instance_types" {
  type        = list(string)
  default     = ["t3.medium"]
  description = "Used for the system node group (CoreDNS, Karpenter, etc.)"
}

variable "system_node_desired_size" {
  type    = number
  default = 2
}

variable "system_node_min_size" {
  type    = number
  default = 2
}

variable "system_node_max_size" {
  type    = number
  default = 3
}

variable "tags" {
  type    = map(string)
  default = {}
}

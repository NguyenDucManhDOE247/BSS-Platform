variable "name_prefix" {
  type        = string
  description = "e.g. 'bss-dev'"
}

variable "cluster_name" {
  type = string
}

variable "k8s_version" {
  type    = string
  default = "1.30"
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

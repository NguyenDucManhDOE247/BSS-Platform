variable "name_prefix" { type = string }
variable "cluster_name" { type = string }

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "xray_sampling_rate" {
  type    = number
  default = 0.1
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "name_prefix" { type = string }

variable "service_names" {
  type        = list(string)
  description = "List of service names (one repository per service)"
  default = [
    "customer-service",
    "product-catalog",
    "order-management",
    "billing-service",
    "api-gateway",
    "web-portal",
    "admin-console",
  ]
}

variable "tags" {
  type    = map(string)
  default = {}
}

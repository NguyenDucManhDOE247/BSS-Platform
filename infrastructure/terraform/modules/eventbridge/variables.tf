variable "name_prefix" { type = string }

variable "consumers" {
  description = "Map of consumer_name => { event_pattern, visibility_timeout_seconds, max_receive_count }"
  type = map(object({
    event_pattern              = string
    visibility_timeout_seconds = number
    max_receive_count          = number
  }))
  default = {
    billing-orders = {
      event_pattern = jsonencode({
        source      = ["bss.order"]
        detail-type = ["OrderCompleted", "OrderRefunded"]
      })
      visibility_timeout_seconds = 60
      max_receive_count          = 5
    }
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

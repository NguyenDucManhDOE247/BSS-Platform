variable "name_prefix" { type = string }

variable "consumers" {
  description = "Map of consumer_name => { event_pattern, visibility_timeout_seconds, max_receive_count }"
  type = map(object({
    event_pattern              = string
    visibility_timeout_seconds = number
    max_receive_count          = number
  }))
  # B-30: a variable `default` must be a constant expression — Terraform's parser rejects any
  # function call here (including `jsonencode(...)`) with "Function calls not allowed", even
  # though the exact same call is fine anywhere else (e.g. main.tf below). The value is just the
  # literal JSON that `jsonencode({ source = ["bss.order"], detail-type = [...] })` would produce
  # (jsonencode sorts object keys alphabetically, hence "detail-type" before "source").
  default = {
    billing-orders = {
      event_pattern              = "{\"detail-type\":[\"OrderCompleted\",\"OrderRefunded\"],\"source\":[\"bss.order\"]}"
      visibility_timeout_seconds = 60
      max_receive_count          = 5
    }
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

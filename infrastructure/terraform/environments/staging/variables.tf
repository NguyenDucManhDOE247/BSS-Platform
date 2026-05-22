variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "owner_email" {
  type = string
}

variable "public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

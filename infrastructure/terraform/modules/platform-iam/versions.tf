terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Only used to fetch the AWS Load Balancer Controller's official IAM policy JSON at
    # plan/apply time (see the data "http" block in main.tf) — needs no provider configuration
    # block of its own.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

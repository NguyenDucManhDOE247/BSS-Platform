terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Only used for the time_sleep between the runner role's policy and the CodeBuild project (see main.tf) —
    # needs no provider configuration block of its own.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

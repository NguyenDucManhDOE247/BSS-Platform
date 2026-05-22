# BSS Platform — STAGING environment
#
# Mirror of prod, sized smaller for pre-production validation:
#   - Single NAT Gateway
#   - Multi-AZ off (cost)
#   - Deletion protection ON

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }

  # backend "s3" {
  #   bucket         = "bss-platform-tfstate"
  #   key            = "staging/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   dynamodb_table = "bss-platform-tflocks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region
  default_tags { tags = local.common_tags }
}

locals {
  env          = "staging"
  name_prefix  = "bss-${local.env}"
  cluster_name = "${local.name_prefix}-eks"

  common_tags = {
    Project     = "bss-platform"
    Environment = local.env
    ManagedBy   = "terraform"
    Owner       = var.owner_email
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name_prefix          = local.name_prefix
  region               = var.region
  cluster_name         = local.cluster_name
  vpc_cidr             = "10.20.0.0/16"
  az_count             = 3
  enable_nat_gateway   = true # needed for E2E test traffic out
  enable_vpc_endpoints = true

  tags = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  name_prefix                = local.name_prefix
  cluster_name               = local.cluster_name
  k8s_version                = "1.30"
  private_subnet_ids         = module.vpc.private_subnet_ids
  public_subnet_ids          = module.vpc.public_subnet_ids
  public_access_cidrs        = var.public_access_cidrs
  system_node_instance_types = ["t3.large"]
  system_node_desired_size   = 2
  system_node_min_size       = 2
  system_node_max_size       = 5

  tags = local.common_tags
}

module "ecr" {
  source      = "../../modules/ecr"
  name_prefix = "bss"
  tags        = local.common_tags
}

module "rds" {
  source = "../../modules/rds"

  name_prefix                = local.name_prefix
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id

  instance_class               = "db.t3.small"
  allocated_storage            = 50
  multi_az                     = false
  backup_retention_days        = 7
  performance_insights_enabled = true
  deletion_protection          = true

  tags = local.common_tags
}

module "eventbridge" {
  source      = "../../modules/eventbridge"
  name_prefix = local.name_prefix
  tags        = local.common_tags
}

module "observability" {
  source = "../../modules/observability"

  name_prefix        = local.name_prefix
  cluster_name       = local.cluster_name
  log_retention_days = 14
  xray_sampling_rate = 0.2

  tags = local.common_tags
}

module "iam" {
  source = "../../modules/iam"

  name_prefix               = local.name_prefix
  cluster_oidc_provider_arn = module.eks.cluster_oidc_provider_arn
  cluster_oidc_provider_url = module.eks.cluster_oidc_provider_url

  services = {
    customer-service = {
      namespace                = "bss"
      service_account          = "customer-service"
      managed_policy_arns      = []
      inline_policy_statements = [
        { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [module.rds.master_secret_arn] }
      ]
    }
    order-management = {
      namespace                = "bss"
      service_account          = "order-management"
      managed_policy_arns      = []
      inline_policy_statements = [
        { Effect = "Allow", Action = ["events:PutEvents"], Resource = module.eventbridge.event_bus_arn },
        { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [module.rds.master_secret_arn] }
      ]
    }
    billing-service = {
      namespace                = "bss"
      service_account          = "billing-service"
      managed_policy_arns      = []
      inline_policy_statements = [
        { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = [module.eventbridge.queue_arns["billing-orders"]] },
        { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [module.rds.master_secret_arn] }
      ]
    }
  }

  # GitHub OIDC provider is created in dev only (account-level resource).
  enable_github_oidc = false

  tags = local.common_tags
}

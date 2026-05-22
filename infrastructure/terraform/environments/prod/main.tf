# BSS Platform — PROD environment
#
# Production-grade defaults:
#   - 3 AZs
#   - NAT Gateway (HA)
#   - Multi-AZ RDS, db.t3.medium+
#   - Deletion protection ON for everything
#   - Restricted EKS public endpoint

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }

  # backend "s3" {
  #   bucket         = "bss-platform-tfstate"
  #   key            = "prod/terraform.tfstate"
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
  env          = "prod"
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
  vpc_cidr             = "10.30.0.0/16"
  az_count             = 3
  enable_nat_gateway   = true
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
  public_access_cidrs        = var.public_access_cidrs # MUST be restricted
  system_node_instance_types = ["t3.large"]
  system_node_desired_size   = 3
  system_node_min_size       = 3
  system_node_max_size       = 6

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

  instance_class               = "db.t3.medium"
  allocated_storage            = 100
  multi_az                     = true
  backup_retention_days        = 30
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
  log_retention_days = 30
  xray_sampling_rate = 0.05

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

  enable_github_oidc = false

  tags = local.common_tags
}

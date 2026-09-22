# BSS Platform — DEV environment
#
# Optimised for low cost and fast iteration:
#   - No NAT Gateway (use VPC endpoints)
#   - Single-AZ RDS, db.t3.micro
#   - System node group min=2 (cheapest stable size)
#   - Deletion protection OFF (so we can `terraform destroy` nightly)

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Remote state (uncomment once the bucket exists — see scripts/bootstrap-aws.sh)
  # backend "s3" {
  #   bucket         = "bss-platform-tfstate"
  #   key            = "dev/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   dynamodb_table = "bss-platform-tflocks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  env          = "dev"
  name_prefix  = "bss-${local.env}"
  cluster_name = "${local.name_prefix}-eks"

  common_tags = {
    Project     = "bss-platform"
    Environment = local.env
    ManagedBy   = "terraform"
    Owner       = var.owner_email
  }
}

# ── VPC ────────────────────────────────────────────────────────────────
module "vpc" {
  source = "../../modules/vpc"

  name_prefix          = local.name_prefix
  region               = var.region
  cluster_name         = local.cluster_name
  vpc_cidr             = "10.10.0.0/16"
  az_count             = 2
  enable_nat_gateway   = false # cost optimization
  enable_vpc_endpoints = true

  tags = local.common_tags
}

# ── EKS ────────────────────────────────────────────────────────────────
module "eks" {
  source = "../../modules/eks"

  name_prefix                = local.name_prefix
  cluster_name               = local.cluster_name
  k8s_version                = "1.30"
  private_subnet_ids         = module.vpc.private_subnet_ids
  public_subnet_ids          = module.vpc.public_subnet_ids
  public_access_cidrs        = var.public_access_cidrs
  system_node_instance_types = ["t3.medium"]
  system_node_desired_size   = 2
  system_node_min_size       = 2
  system_node_max_size       = 3

  tags = local.common_tags
}

# ── ECR ────────────────────────────────────────────────────────────────
module "ecr" {
  source      = "../../modules/ecr"
  name_prefix = "bss" # shared across envs (same image, multiple deploys)

  tags = local.common_tags
}

# ── RDS ────────────────────────────────────────────────────────────────
module "rds" {
  source = "../../modules/rds"

  name_prefix                = local.name_prefix
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id

  instance_class               = "db.t3.micro"
  allocated_storage            = 20
  multi_az                     = false
  backup_retention_days        = 1
  performance_insights_enabled = false
  deletion_protection          = false

  tags = local.common_tags
}

# ── EventBridge + SQS ──────────────────────────────────────────────────
module "eventbridge" {
  source      = "../../modules/eventbridge"
  name_prefix = local.name_prefix

  tags = local.common_tags
}

# ── Platform addon IAM (B-35) ────────────────────────────────────────────
module "platform_iam" {
  source = "../../modules/platform-iam"

  name_prefix               = local.name_prefix
  cluster_oidc_provider_arn = module.eks.cluster_oidc_provider_arn
  cluster_oidc_provider_url = module.eks.cluster_oidc_provider_url

  tags = local.common_tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.platform_iam.ebs_csi_role_arn
}

# ── Observability ──────────────────────────────────────────────────────
module "observability" {
  source = "../../modules/observability"

  name_prefix        = local.name_prefix
  cluster_name       = local.cluster_name
  log_retention_days = 3 # short for dev
  xray_sampling_rate = 0.5

  tags = local.common_tags
}

# ── IAM (IRSA roles + GitHub OIDC) ─────────────────────────────────────
module "iam" {
  source = "../../modules/iam"

  name_prefix               = local.name_prefix
  cluster_oidc_provider_arn = module.eks.cluster_oidc_provider_arn
  cluster_oidc_provider_url = module.eks.cluster_oidc_provider_url

  services = {
    customer-service = {
      namespace           = "bss"
      service_account     = "customer-service"
      managed_policy_arns = []
      inline_policy_statements = [
        {
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
          Resource = [module.rds.master_secret_arn]
        }
      ]
    }
    order-management = {
      namespace           = "bss"
      service_account     = "order-management"
      managed_policy_arns = []
      inline_policy_statements = [
        {
          Effect = "Allow"
          Action = ["events:PutEvents"]
          # B-31: must be a list, not a bare string — `inline_policy_statements` is typed
          # `list(any)`, and every OTHER statement in this map already uses a list `Resource`
          # (see the secretsmanager statement right below). Terraform has to convert every
          # object in the map to one unified type; a lone bare-string Resource here breaks that
          # unification with "element types must all match for conversion to list".
          Resource = [module.eventbridge.event_bus_arn]
        },
        {
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = [module.rds.master_secret_arn]
        }
      ]
    }
    billing-service = {
      namespace           = "bss"
      service_account     = "billing-service"
      managed_policy_arns = []
      inline_policy_statements = [
        {
          Effect   = "Allow"
          Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
          Resource = [module.eventbridge.queue_arns["billing-orders"]]
        },
        {
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = [module.rds.master_secret_arn]
        }
      ]
    }
  }

  enable_github_oidc = true
  github_repos       = var.github_repos

  tags = local.common_tags
}

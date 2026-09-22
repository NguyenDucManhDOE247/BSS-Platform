# BSS Platform — DEV environment
#
# Optimised for low cost and fast iteration:
#   - 1 NAT Gateway (not "VPC endpoints only" — see docs/adr/ADR-002-mang-dev.md, B-32)
#   - Single-AZ RDS, db.t3.micro
#   - System node group min=2 (cheapest stable size)
#   - Deletion protection OFF (so we can `terraform destroy` nightly)

terraform {
  required_version = ">= 1.10" # use_lockfile (S3 native state lock, B-38) needs 1.10+

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

  # Remote state — bucket deliberately NOT hardcoded here (B-38: S3 bucket names are global, so
  # the bucket name embeds your AWS account id, e.g. "bss-tfstate-123456789012", which this file
  # can't know statically). Run `scripts/bootstrap-aws.sh` first, then either:
  #   terraform init -backend-config="bucket=bss-tfstate-<your-account-id>"
  # or simply `make ENV=dev tf-init` (the Makefile fills in -backend-config from
  # `aws sts get-caller-identity` for you). `use_lockfile` needs Terraform >= 1.10 — no DynamoDB
  # table to create/pay for separately anymore.
  backend "s3" {
    key          = "dev/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}

# B-33: ECR + GitHub OIDC + deployer roles live in environments/shared now (account-level,
# outlive any single environment) — read their outputs instead of re-creating them here.
# Requires `environments/shared` to have been applied FIRST.
data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "bss-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "shared/terraform.tfstate"
    region = var.region
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

  name_prefix                = local.name_prefix
  region                     = var.region
  cluster_name               = local.cluster_name
  vpc_cidr                   = "10.10.0.0/16"
  az_count                   = 2
  enable_nat_gateway         = true  # B-32/ADR-002: "no NAT" didn't work — see the ADR
  enable_interface_endpoints = false # S3 gateway endpoint is still always on (free)

  tags = local.common_tags
}

# ── EKS ────────────────────────────────────────────────────────────────
module "eks" {
  source = "../../modules/eks"

  name_prefix                = local.name_prefix
  cluster_name               = local.cluster_name
  k8s_version                = "1.34" # B-36: verify current STANDARD_SUPPORT versions before apply
  private_subnet_ids         = module.vpc.private_subnet_ids
  public_subnet_ids          = module.vpc.public_subnet_ids
  public_access_cidrs        = var.public_access_cidrs
  system_node_instance_types = ["t3.medium"]
  system_node_desired_size   = 2
  system_node_min_size       = 2
  system_node_max_size       = 3

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
  secret_recovery_window_days  = 0 # B-37: dev gets destroyed/re-applied daily — see module comment

  tags = local.common_tags
}

# ── EventBridge + SQS ──────────────────────────────────────────────────
module "eventbridge" {
  source      = "../../modules/eventbridge"
  name_prefix = local.name_prefix

  tags = local.common_tags
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

# ── IAM (per-service IRSA roles — GitHub OIDC lives in environments/shared) ─
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

  tags = local.common_tags
}

# ── B-34: EKS access entry for the CI/CD deployer role ──────────────────
# `eks:DescribeCluster` (granted in environments/shared) only lets GitHub Actions fetch
# connection details — it does NOT authorize anything once `kubectl` actually talks to the
# cluster's API server. That's a SEPARATE authorization layer (EKS access entries, replacing
# the old aws-auth ConfigMap) which this resource grants, scoped to just the `bss` namespace
# (not cluster-admin).
resource "aws_eks_access_entry" "deployer_nonprod" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.terraform_remote_state.shared.outputs.deployer_nonprod_role_arn
}

resource "aws_eks_access_policy_association" "deployer_nonprod_bss" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.terraform_remote_state.shared.outputs.deployer_nonprod_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["bss"]
  }
}

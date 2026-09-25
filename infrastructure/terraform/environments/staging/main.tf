# BSS Platform — STAGING environment
#
# Mirror of prod, sized smaller for pre-production validation:
#   - Single NAT Gateway
#   - Multi-AZ off (cost)
#   - Deletion protection ON

terraform {
  required_version = ">= 1.10" # use_lockfile (S3 native state lock, B-38) needs 1.10+

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }

  # Remote state — see the long comment in environments/dev/main.tf (B-38): bucket name comes
  # from `-backend-config` (or `make ENV=staging tf-init`), not hardcoded here.
  backend "s3" {
    key          = "staging/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = local.common_tags }
}

data "aws_caller_identity" "current" {}

# B-33: ECR + GitHub OIDC + deployer roles live in environments/shared (account-level) — see
# the matching, longer comment in environments/dev/main.tf.
data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "bss-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "shared/terraform.tfstate"
    region = var.region
  }
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

  name_prefix                = local.name_prefix
  region                     = var.region
  cluster_name               = local.cluster_name
  vpc_cidr                   = "10.20.0.0/16"
  az_count                   = 3
  enable_nat_gateway         = true  # needed for E2E test traffic out
  enable_interface_endpoints = false # NAT already covers this — see ADR-002 (B-32)

  tags = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  name_prefix                = local.name_prefix
  cluster_name               = local.cluster_name
  k8s_version                = "1.34" # B-36: verify current STANDARD_SUPPORT versions before apply
  private_subnet_ids         = module.vpc.private_subnet_ids
  public_subnet_ids          = module.vpc.public_subnet_ids
  public_access_cidrs        = var.public_access_cidrs
  system_node_instance_types = ["t3.large"]
  system_node_desired_size   = 2
  system_node_min_size       = 2
  system_node_max_size       = 5

  tags = local.common_tags
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
  deletion_protection          = !var.ephemeral
  secret_recovery_window_days  = var.ephemeral ? 0 : 30 # B-37: see var.ephemeral

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

module "iam" {
  source = "../../modules/iam"

  name_prefix               = local.name_prefix
  cluster_oidc_provider_arn = module.eks.cluster_oidc_provider_arn
  cluster_oidc_provider_url = module.eks.cluster_oidc_provider_url

  # Giai đoạn 6 (ADR-006): brought to parity with environments/dev (Giai đoạn 5, B-20/B-21, ADR-004).
  # This block had drifted — every service still read the RDS MASTER secret (one shared superuser for
  # all databases) and `product-catalog` had no role at all (its ServiceAccount would be annotated with
  # a role that doesn't exist). Now each service may read ONLY its own least-privilege secret.
  services = {
    customer-service = {
      namespace           = "bss"
      service_account     = "customer-service"
      managed_policy_arns = []
      inline_policy_statements = [
        {
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
          Resource = [module.rds.service_secret_arns["customer-service"]]
        }
      ]
    }
    product-catalog = {
      namespace           = "bss"
      service_account     = "product-catalog"
      managed_policy_arns = []
      inline_policy_statements = [
        {
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
          Resource = [module.rds.service_secret_arns["product-catalog"]]
        }
      ]
    }
    order-management = {
      namespace           = "bss"
      service_account     = "order-management"
      managed_policy_arns = []
      inline_policy_statements = [
        {
          Effect   = "Allow"
          Action   = ["events:PutEvents"]
          Resource = [module.eventbridge.event_bus_arn] # B-31: a list, not a bare string
        },
        {
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = [module.rds.service_secret_arns["order-management"]]
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
          Resource = [module.rds.service_secret_arns["billing-service"]]
        }
      ]
    }
    # B-21: read-only access to the master secret + the 4 per-service secrets, for the one-off
    # db-bootstrap Job (overlays/staging/db-bootstrap/README.md). The only ServiceAccount in the cluster
    # that can read the master password.
    db-bootstrap = {
      namespace           = "bss"
      service_account     = "db-bootstrap"
      managed_policy_arns = []
      inline_policy_statements = [
        {
          Effect = "Allow"
          Action = ["secretsmanager:GetSecretValue"]
          # A literal list on purpose (not concat()/values() of a module output) — mixing `list(string)`
          # and `tuple` breaks type unification across this whole `services` map, same family as B-31.
          Resource = [
            module.rds.master_secret_arn,
            module.rds.service_secret_arns["customer-service"],
            module.rds.service_secret_arns["product-catalog"],
            module.rds.service_secret_arns["order-management"],
            module.rds.service_secret_arns["billing-service"],
          ]
        }
      ]
    }
  }

  tags = local.common_tags
}

# ── B-34: EKS access entry for the CI/CD deployer role (staging's own role — B-39) ─────
resource "aws_eks_access_entry" "deployer" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.terraform_remote_state.shared.outputs.deployer_role_arns["staging"]
}

resource "aws_eks_access_policy_association" "deployer_bss" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.terraform_remote_state.shared.outputs.deployer_role_arns["staging"]
  # Giai đoạn 6: EditPolicy does NOT cover the Secrets Store CSI CRD (SecretProviderClass) — found by the first
  # real cd-dev run (preflight `kubectl auth can-i` said so). ClusterAdminPolicy is still bounded by
  # `access_scope` below to namespace `bss` only (no cluster-wide power, cannot touch other namespaces).
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["bss"]
  }

  # See the long comment on the equivalent resource in environments/dev/main.tf — AWS requires
  # the access entry to exist before a policy can be associated with that principal; without
  # this, Terraform may create both in parallel and race.
  depends_on = [aws_eks_access_entry.deployer]
}

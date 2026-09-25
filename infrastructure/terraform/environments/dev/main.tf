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

# ── IAM (per-service IRSA roles — GitHub OIDC lives in environments/shared) ─
module "iam" {
  source = "../../modules/iam"

  name_prefix               = local.name_prefix
  cluster_oidc_provider_arn = module.eks.cluster_oidc_provider_arn
  cluster_oidc_provider_url = module.eks.cluster_oidc_provider_url

  services = {
    # Giai đoạn 5 / B-20: mỗi service giờ chỉ được đọc secret DB CỦA RIÊNG NÓ
    # (module.rds.service_secret_arns[<key>], user "<db>_svc" từ B-21) — không còn quyền đọc
    # master_secret_arn nữa. Trước đây cả 3 service này dùng chung master_secret_arn: technically
    # "chạy được" (mọi service share 1 user Postgres, đủ quyền đọc/ghi mọi database trên instance)
    # nhưng vi phạm least privilege — 1 service bị chiếm quyền (RCE, SSRF...) sẽ đọc/ghi được
    # database của MỌI service khác, không chỉ của chính nó. Xem ADR-004.
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
    # B-20 tiếp: product-catalog trước đây KHÔNG có role nào trong map này — SecretProviderClass
    # + Deployment của nó (overlays/dev) tham chiếu một role "bss-dev-product-catalog" mà
    # Terraform chưa từng tạo. Thêm entry này là phần còn thiếu để B-20 chạy được thật cho cả 4
    # service, không phải 3.
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
    # B-21: read-only access to the master secret + all 4 per-service secrets, for the one-off
    # db-bootstrap Job — see infrastructure/kubernetes/overlays/dev/db-bootstrap/README.md.
    # Nothing else should ever assume this role; it's the only SA in the cluster that can read
    # the master password.
    db-bootstrap = {
      namespace           = "bss"
      service_account     = "db-bootstrap"
      managed_policy_arns = []
      inline_policy_statements = [
        {
          Effect = "Allow"
          Action = ["secretsmanager:GetSecretValue"]
          # A literal list, like every other Resource in this map — NOT concat()/values() on a
          # module output. Those return an actual `list(string)`, whereas every literal `[...]`
          # here is a `tuple(...)`; mixing the two breaks type unification across this whole
          # `services` map the same way B-31 did (a bare string vs. a list) — just one level
          # deeper. `terraform validate` catches it either way; don't "simplify" this back.
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

# ── B-34: EKS access entry for the CI/CD deployer role ──────────────────
# `eks:DescribeCluster` (granted in environments/shared) only lets GitHub Actions fetch
# connection details — it does NOT authorize anything once `kubectl` actually talks to the
# cluster's API server. That's a SEPARATE authorization layer (EKS access entries, replacing
# the old aws-auth ConfigMap) which this resource grants, scoped to just the `bss` namespace
# (not cluster-admin).
#
# Giai đoạn 6 (B-39): each environment now has its OWN role (`deployer_role_arns["dev"]`), trusted
# only by jobs running under the GitHub Environment `dev` — no more shared "nonprod" role.
resource "aws_eks_access_entry" "deployer" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.terraform_remote_state.shared.outputs.deployer_role_arns["dev"]
}

resource "aws_eks_access_policy_association" "deployer_bss" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.terraform_remote_state.shared.outputs.deployer_role_arns["dev"]
  # Giai đoạn 6: EditPolicy does NOT cover the Secrets Store CSI CRD (SecretProviderClass) — found by the first
  # real cd-dev run (preflight `kubectl auth can-i` said so). ClusterAdminPolicy is still bounded by
  # `access_scope` below to namespace `bss` only (no cluster-wide power, cannot touch other namespaces).
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["bss"]
  }

  # Real bug found running `terraform apply` against actual AWS (not caught by validate/plan):
  # both this resource and aws_eks_access_entry.deployer reference the same external
  # values (cluster_name, principal_arn) but never reference EACH OTHER, so Terraform has no
  # inferred ordering between them and can create them in either order/in parallel. AWS requires
  # the access ENTRY to exist before you can associate a policy with that principal — without
  # this depends_on, the association's API call can race ahead of the entry and fail with
  # "AssociateAccessPolicy ... 404 ResourceNotFoundException".
  depends_on = [aws_eks_access_entry.deployer]
}

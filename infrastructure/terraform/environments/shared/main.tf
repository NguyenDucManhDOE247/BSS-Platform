# BSS Platform — SHARED environment
#
# Account-level resources that must exist EXACTLY ONCE and outlive any single
# dev/staging/prod environment — see docs/adr/ADR-003-terraform-shared-state.md.
#
#   - ECR repositories (7, one per service — the whole point of "build once, deploy
#     many" is that the SAME image, in the SAME repo, gets promoted across environments)
#   - GitHub OIDC provider (there can only be ONE per AWS account — creating a second
#     "token.actions.githubusercontent.com" provider fails)
#   - 3 CI/CD deployer roles, ONE PER ENVIRONMENT (dev / staging / prod). Each trusts exactly one
#     GitHub *Environment* (see "Deployer roles" below) — B-39, Giai đoạn 6
#
# Apply this FIRST, before dev/staging/prod (they read its outputs via
# `terraform_remote_state`).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # See the matching comment in environments/dev/main.tf (B-38) — bucket name comes from
  # -backend-config, not hardcoded (S3 bucket names are global).
  backend "s3" {
    key          = "shared/terraform.tfstate"
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

locals {
  common_tags = {
    Project     = "bss-platform"
    Environment = "shared"
    ManagedBy   = "terraform"
    Owner       = var.owner_email
  }
}

# ── ECR — one set of repos, shared by every environment ────────────────
module "ecr" {
  source      = "../../modules/ecr"
  name_prefix = "bss"

  tags = local.common_tags
}

# ── GitHub OIDC provider (account-level singleton) ─────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = local.common_tags
}

# ── Deployer roles: one per environment, trust pinned to a GitHub *Environment* (B-39) ─────
# How a GitHub Actions job proves who it is to AWS (OIDC): the JWT it presents has a `sub` claim.
# Its shape depends on what the job declares:
#
#   no `environment:`            -> repo:OWNER/REPO:ref:refs/heads/main      (branch)   <- too broad:
#                                   anything that can push a branch/tag can produce a matching `sub`
#   `environment: production`    -> repo:OWNER/REPO:environment:production   (ref is DROPPED)
#
# Pinning each role's trust to `...:environment:<name>` means "you can only get this role by running
# a job that passed that Environment's protection rules" — required reviewers + allowed branches/tags
# (configured in GitHub, see scripts/setup-github-environments.sh). A pull_request `sub` is not
# trusted by ANY role any more: PR code can no longer obtain credentials that push to ECR (the old
# nonprod trust list included `pull_request`).
#
# `StringEquals` (exact match), not `StringLike` with a wildcard: there is nothing to wildcard.
locals {
  # Key = our environment name (-> role name, and the cluster name bss-<key>-eks).
  # github_environment = the GitHub Environment name the workflow declares (`environment:`).
  # ecr_push = may this role upload NEW image layers? Only dev builds images. Staging/prod promote by
  # adding a tag to an existing manifest (`aws ecr put-image`) — they must not be able to push code.
  deployers = {
    dev     = { github_environment = "dev", ecr_push = true }
    staging = { github_environment = "staging", ecr_push = false }
    prod    = { github_environment = "production", ecr_push = false }
  }

  ecr_repo_arns = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/bss/*"
}

resource "aws_iam_role" "deployer" {
  for_each = local.deployers

  name = "bss-github-deployer-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [
            for repo in var.github_repos : "repo:${repo}:environment:${each.value.github_environment}"
          ]
        }
      }
    }]
  })

  tags = local.common_tags
}

# The prod role already existed under the old address (`aws_iam_role.deployer_prod`) — keep the same
# AWS role (same name, same ARN) instead of destroy + create.
moved {
  from = aws_iam_role.deployer_prod
  to   = aws_iam_role.deployer["prod"]
}

resource "aws_iam_role_policy" "deployer" {
  for_each = local.deployers

  name = "deployer"
  role = aws_iam_role.deployer[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "ECRReadAndTag"
          Effect = "Allow"
          # Read the image manifest + add a tag to it (`aws ecr batch-get-image` / `put-image`), and
          # check whether an image exists (`describe-images`). Scoped to bss/* repos, not "*".
          Action = [
            "ecr:BatchGetImage",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchCheckLayerAvailability",
            "ecr:DescribeImages",
            "ecr:DescribeRepositories",
            "ecr:PutImage",
          ]
          Resource = local.ecr_repo_arns
        },
        {
          # B-34: this only lets `aws eks update-kubeconfig` fetch connection details — kubectl-level
          # authorization is a SEPARATE layer (aws_eks_access_entry in each environment's own state).
          # Scoped to THIS environment's cluster: the dev role cannot even describe the prod cluster.
          Sid      = "EKSDescribeOwnCluster"
          Effect   = "Allow"
          Action   = ["eks:DescribeCluster"]
          Resource = "arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/bss-${each.key}-eks"
        },
      ],
      each.value.ecr_push ? [
        {
          Sid      = "ECRLogin"
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = "*" # this one action does not support resource-level scoping
        },
        {
          Sid    = "ECRPushLayers"
          Effect = "Allow"
          Action = [
            "ecr:InitiateLayerUpload",
            "ecr:UploadLayerPart",
            "ecr:CompleteLayerUpload",
          ]
          Resource = local.ecr_repo_arns
        },
      ] : []
    )
  })
}

moved {
  from = aws_iam_role_policy.deployer_prod
  to   = aws_iam_role_policy.deployer["prod"]
}

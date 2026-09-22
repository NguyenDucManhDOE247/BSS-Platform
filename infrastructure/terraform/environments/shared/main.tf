# BSS Platform — SHARED environment
#
# Account-level resources that must exist EXACTLY ONCE and outlive any single
# dev/staging/prod environment — see docs/adr/ADR-003-terraform-shared-state.md.
#
#   - ECR repositories (7, one per service — the whole point of "build once, deploy
#     many" is that the SAME image, in the SAME repo, gets promoted across environments)
#   - GitHub OIDC provider (there can only be ONE per AWS account — creating a second
#     "token.actions.githubusercontent.com" provider fails)
#   - 2 CI/CD deployer roles (nonprod: dev+staging, prod: prod only — least privilege,
#     separate blast radius)
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

# ── Deployer role: nonprod (dev + staging) ──────────────────────────────
# Trusted by: merges to main (cd-dev), rc-v* tags (cd-staging), and pull_request runs
# (ci-terraform's plan-dev job, read-mostly). B-39: this is still narrower than the
# original `repo:<repo>:*` (which trusted literally every branch/tag/PR/environment).
resource "aws_iam_role" "deployer_nonprod" {
  name = "bss-github-deployer-nonprod"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = flatten([
            for repo in var.github_repos : [
              "repo:${repo}:ref:refs/heads/main",
              "repo:${repo}:ref:refs/tags/rc-v*",
              "repo:${repo}:pull_request",
            ]
          ])
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "deployer_nonprod" {
  name   = "deployer"
  role   = aws_iam_role.deployer_nonprod.id
  policy = local.deployer_policy_json
}

# ── Deployer role: prod ─────────────────────────────────────────────────
# Trusted ONLY by v* tags (matches cd-prod.yml's trigger). ⚠️ Still repo-wide rather than
# scoped to a GitHub Environment with required reviewers — that needs GitHub Environments
# configured first (Giai đoạn 6, B-39 follow-up), tighten the condition to
# "repo:<repo>:environment:production" once that exists.
resource "aws_iam_role" "deployer_prod" {
  name = "bss-github-deployer-prod"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            for repo in var.github_repos : "repo:${repo}:ref:refs/tags/v*"
          ]
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "deployer_prod" {
  name   = "deployer"
  role   = aws_iam_role.deployer_prod.id
  policy = local.deployer_policy_json
}

# ── Shared policy document (both roles get the same permissions today) ─
# B-34: EKS access — kubectl-level authorization — is granted SEPARATELY, per cluster, via
# `aws_eks_access_entry` in each environment's own main.tf (an access entry needs
# `cluster_name`, which only the environment's own state knows). `eks:DescribeCluster` here is
# only what `aws eks update-kubeconfig` needs to fetch connection details — it does NOT grant
# any Kubernetes RBAC permission by itself (that's the classic IAM-vs-K8s-RBAC confusion B-34
# was about).
locals {
  deployer_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
        ]
        Resource = "*"
      },
      {
        Sid      = "EKSDescribe"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListClusters"]
        Resource = "*"
      },
    ]
  })
}

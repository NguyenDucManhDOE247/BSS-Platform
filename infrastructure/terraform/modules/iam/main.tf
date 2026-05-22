# IRSA roles for each service. Each role is assumable ONLY by a specific
# Kubernetes ServiceAccount (namespace + name pair) via the cluster OIDC provider.
#
# This is the AWS equivalent of GCP's Workload Identity:
# pods can call AWS APIs without ever holding static credentials.

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_iam_role" "service" {
  for_each = var.services

  name = "${var.name_prefix}-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.cluster_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.cluster_oidc_provider_url}:sub" = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
          "${var.cluster_oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

# ── Inline policies (per service) ──────────────────────────────────────
resource "aws_iam_role_policy" "service_inline" {
  for_each = { for k, v in var.services : k => v if length(v.inline_policy_statements) > 0 }

  name = "${var.name_prefix}-${each.key}-inline"
  role = aws_iam_role.service[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = each.value.inline_policy_statements
  })
}

# ── Managed policy attachments (per service) ───────────────────────────
resource "aws_iam_role_policy_attachment" "service_managed" {
  for_each = merge([
    for service_name, service_cfg in var.services : {
      for policy_arn in service_cfg.managed_policy_arns :
      "${service_name}__${replace(policy_arn, "/[^a-zA-Z0-9]/", "_")}" => {
        service    = service_name
        policy_arn = policy_arn
      }
    }
  ]...)

  role       = aws_iam_role.service[each.value.service].name
  policy_arn = each.value.policy_arn
}

# ── GitHub OIDC provider (for CI/CD) ───────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

resource "aws_iam_role" "github_actions_deployer" {
  count = var.enable_github_oidc ? 1 : 0

  name = "${var.name_prefix}-github-deployer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            for repo in var.github_repos : "repo:${repo}:*"
          ]
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "github_actions_deployer" {
  count = var.enable_github_oidc ? 1 : 0

  name = "deployer"
  role = aws_iam_role.github_actions_deployer[0].id

  policy = jsonencode({
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

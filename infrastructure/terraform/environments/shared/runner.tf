# Kết nối AWS ↔ GitHub cho runner CD trong VPC (ADR-013, modules/ci-runner).
#
# Nằm ở state shared vì nó sống lâu hơn môi trường (như ECR, OIDC, zone DNS): bước ủy quyền phải làm TAY một lần
# trong console — Terraform chỉ tạo được kết nối ở trạng thái PENDING:
#
#   AWS Console → Developer Tools → Settings → Connections → bss-github → "Update pending connection"
#   → cài GitHub App "AWS Connector for GitHub" cho đúng repo → trạng thái thành AVAILABLE.
#
# Staging/prod đọc ARN này qua remote state; khi chưa AVAILABLE, module ci-runner không tạo được webhook
# (lỗi rõ ràng lúc apply) — xem docs/runbooks/cd-runner.md.
resource "aws_codeconnections_connection" "github" {
  name          = "bss-github"
  provider_type = "GitHub"

  tags = local.common_tags
}

# ── Role "preflight" cho cd-staging / cd-prod ──────────────────────────────────────────────────────────────
# Job deploy chạy trên runner CodeBuild của môi trường. Môi trường là ephemeral (ADR-006): chưa dựng thì project
# runner không tồn tại và job sẽ nằm trong hàng đợi vô thời hạn thay vì báo lỗi. Một job nhỏ chạy TRƯỚC, trên
# runner của GitHub, hỏi "cluster ACTIVE chưa, project runner có chưa" rồi mới cho job deploy xếp hàng.
#
# Vì sao không dùng role deployer cho việc này: trust của deployer gắn với GitHub Environment (B-39), mà
# Environment `production` có Required reviewers → job kiểm cũng phải chờ duyệt, tức duyệt 2 lần cho 1 lần
# deploy. Role này tin theo REF của tag (rc-v* / v*), không qua Environment — và vì thế chỉ được ĐỌC đúng 2 thứ
# metadata, không đụng được ECR, không vào được cluster (không có EKS access entry).
locals {
  runner_envs = ["staging", "prod"]
}

resource "aws_iam_role" "cd_preflight" {
  name = "bss-github-cd-preflight"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = flatten([
            for prefix in local.github_sub_prefixes : ["${prefix}:ref:refs/tags/rc-v*", "${prefix}:ref:refs/tags/v*"]
          ])
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "cd_preflight" {
  name = "preflight"
  role = aws_iam_role.cd_preflight.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ClusterStatus"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = [for env in local.runner_envs : "arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/bss-${env}-eks"]
      },
      {
        Sid      = "RunnerProjectExists"
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetProjects"]
        Resource = [for env in local.runner_envs : "arn:aws:codebuild:${var.region}:${data.aws_caller_identity.current.account_id}:project/bss-${env}-gha-runner"]
      },
    ]
  })
}

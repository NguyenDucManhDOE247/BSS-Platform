# Runner GitHub Actions chạy TRONG VPC bằng AWS CodeBuild (ADR-013).
#
# Vì sao: runner do GitHub host không có IP cố định (hàng nghìn dải, EKS nhận tối đa 40 CIDR) → muốn CD chạy
# kubectl thì endpoint public của EKS phải mở 0.0.0.0/0 — ngoại lệ đã ghi ở CLAUDE.md §10 từ GĐ6. Runner này
# nằm ở subnet private và gọi API server qua endpoint PRIVATE của cluster, nên endpoint public chỉ còn cần IP
# của người vận hành.
#
# Vì sao CodeBuild mà không phải EC2 tự nuôi: không có máy nào để vá/giám sát; mỗi job là một container mới
# (như runner của GitHub); trả theo phút build; và nó biến mất cùng môi trường ephemeral (ADR-006).
#
# Runner KHÔNG mang quyền deploy: role của project chỉ đủ để chạy container + ghi log. Job vẫn lấy quyền như cũ
# — GitHub OIDC → role bss-github-deployer-<env> (trust theo GitHub Environment, B-39).
#
# Cách dùng trong workflow:
#   runs-on: codebuild-<project_name>-${{ github.run_id }}-${{ github.run_attempt }}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  project_name = "${var.name_prefix}-gha-runner"
  account_arn  = "arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}"
}

# ── Mạng: runner chỉ đi RA (GitHub, ECR, STS qua NAT; API server qua endpoint private) ─────────────────────
resource "aws_security_group" "runner" {
  name        = "${var.name_prefix}-gha-runner"
  description = "GitHub Actions runner (CodeBuild) - egress only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-gha-runner" })
}

resource "aws_vpc_security_group_egress_rule" "runner_all" {
  security_group_id = aws_security_group.runner.id
  description       = "GitHub, ECR, STS qua NAT; EKS API qua endpoint private"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0" # trivy:ignore:AVD-AWS-0104 runner phải ra GitHub (không có dải IP cố định)
}

# API server (ENI của control plane mang cluster security group) nhận 443 từ ĐÚNG security group của runner.
resource "aws_vpc_security_group_ingress_rule" "cluster_from_runner" {
  security_group_id            = var.cluster_security_group_id
  description                  = "kubectl tu runner CD trong VPC"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.runner.id
}

# ── IAM: chỉ đủ để CodeBuild chạy container trong VPC + ghi log + dùng kết nối GitHub ───────────────────────
resource "aws_iam_role" "runner" {
  name = "${var.name_prefix}-gha-runner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "runner" {
  name = "runner"
  role = aws_iam_role.runner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.runner.arn}:*"
      },
      {
        Sid    = "GitHubConnection"
        Effect = "Allow"
        Action = [
          "codeconnections:GetConnectionToken",
          "codeconnections:GetConnection",
          "codeconnections:UseConnection",
          "codestar-connections:GetConnectionToken",
          "codestar-connections:GetConnection",
          "codestar-connections:UseConnection",
        ]
        Resource = var.github_connection_arn
      },
      {
        # CodeBuild gắn 1 ENI vào subnet private cho mỗi build. Các action này không hỗ trợ giới hạn theo
        # resource — phần được giới hạn là AI được dùng ENI đó (statement kế tiếp).
        Sid    = "VpcNetworkInterfaces"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeDhcpOptions",
          "ec2:DescribeVpcs",
        ]
        Resource = "*"
      },
      {
        Sid      = "VpcNetworkInterfacePermission"
        Effect   = "Allow"
        Action   = ["ec2:CreateNetworkInterfacePermission"]
        Resource = "${local.account_arn}:network-interface/*"
        Condition = {
          StringEquals = { "ec2:AuthorizedService" = "codebuild.amazonaws.com" }
          ArnEquals    = { "ec2:Subnet" = [for id in var.private_subnet_ids : "${local.account_arn}:subnet/${id}"] }
        }
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "runner" {
  name              = "/aws/codebuild/${local.project_name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# ── Project CodeBuild = "runner" ──────────────────────────────────────────────────────────────────────────
resource "aws_codebuild_project" "runner" {
  name          = local.project_name
  description   = "GitHub Actions runner trong VPC cho CD ${var.name_prefix} (ADR-013)"
  service_role  = aws_iam_role.runner.arn
  build_timeout = 60

  source {
    type            = "GITHUB"
    location        = "https://github.com/${var.github_repo}.git"
    git_clone_depth = 1
    # Với project làm runner, CodeBuild bỏ qua buildspec và chạy job của GitHub Actions.
    buildspec = yamlencode({
      version = 0.2
      phases  = { build = { commands = ["echo project nay chi lam GitHub Actions runner"] } }
    })

    auth {
      type     = "CODECONNECTIONS"
      resource = var.github_connection_arn
    }
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = var.image
    privileged_mode = false # job CD không build image (promotion = aws ecr put-image)
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.private_subnet_ids
    security_group_ids = [aws_security_group.runner.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.runner.name
    }
  }

  tags = var.tags

  depends_on = [time_sleep.runner_iam_propagation]
}

# CreateProject kiểm NGAY rằng service role đọc được kết nối GitHub, mà policy vừa gắn cần vài giây mới có hiệu
# lực ở mọi nơi (IAM eventually consistent). Không chờ thì apply đầu tiên của một môi trường mới vỡ với
# "OAuthProviderException: User is not authorized to access connection …" (gặp thật khi dựng staging 2026-10-05;
# apply lại lần hai thì qua). Provider AWS không tự retry lỗi này.
resource "time_sleep" "runner_iam_propagation" {
  create_duration = "30s"

  triggers = {
    policy = aws_iam_role_policy.runner.policy
  }
}

# GitHub gửi sự kiện "có job đang chờ runner" → CodeBuild khởi động 1 build làm runner cho đúng job đó.
resource "aws_codebuild_webhook" "runner" {
  project_name = aws_codebuild_project.runner.name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "WORKFLOW_JOB_QUEUED"
    }
  }
}

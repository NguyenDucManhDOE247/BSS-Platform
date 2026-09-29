# ── Fluent Bit + OTel Collector (dọn nợ GĐ7) ─────────────────────────────────────────────────────
# GĐ7 việc 2–3 chỉ từng chạy trên kind (sink cục bộ). Lần đầu chạy scripts/logging-install.sh dev /
# tracing-install.sh dev trên EKS thật (2026-09-29) mới lộ ra: 2 script đọc output fluent_bit_role_arn /
# otel_collector_role_arn nhưng CHƯA role nào tồn tại (comment đầu main.tf còn ghi "chưa làm").

# Fluent Bit (namespace amazon-cloudwatch, SA fluent-bit — platform/logging/fluent-bit-values.yaml):
# chỉ ghi vào các log group /aws/eks/<cluster>/* do modules/observability tạo sẵn.
resource "aws_iam_role" "fluent_bit" {
  name = "${var.name_prefix}-fluent-bit"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.cluster_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = merge(local.oidc_trust_condition.StringEquals, {
          "${var.cluster_oidc_provider_url}:sub" = "system:serviceaccount:amazon-cloudwatch:fluent-bit"
        })
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "fluent_bit" {
  name = "cloudwatch-logs"
  role = aws_iam_role.fluent_bit.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteClusterLogGroups"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = ["arn:${local.kp_partition}:logs:${local.kp_region}:${local.kp_account}:log-group:/aws/eks/${var.cluster_name}/*"]
      },
      {
        Sid      = "DescribeLogGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
    ]
  })
}

# OTel Collector (namespace observability, SA otel-collector — platform/tracing/otel-collector-values.yaml):
# exporter awsxray chỉ cần quyền ghi trace + đọc sampling rule — đúng managed policy của AWS.
resource "aws_iam_role" "otel_collector" {
  name = "${var.name_prefix}-otel-collector"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.cluster_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = merge(local.oidc_trust_condition.StringEquals, {
          "${var.cluster_oidc_provider_url}:sub" = "system:serviceaccount:observability:otel-collector"
        })
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "otel_collector_xray" {
  role       = aws_iam_role.otel_collector.name
  policy_arn = "arn:${local.kp_partition}:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

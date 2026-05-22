# CloudWatch log groups for application logs (Fluent Bit ships pod logs here).
# X-Ray sampling rule for tracing.
#
# Prometheus + Grafana run inside the cluster (see platform/monitoring/),
# not in CloudWatch — CloudWatch is for logs + AWS-native metrics only.

resource "aws_cloudwatch_log_group" "application" {
  name              = "/aws/eks/${var.cluster_name}/application"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "dataplane" {
  name              = "/aws/eks/${var.cluster_name}/dataplane"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "host" {
  name              = "/aws/eks/${var.cluster_name}/host"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ── X-Ray sampling rule ────────────────────────────────────────────────
resource "aws_xray_sampling_rule" "bss" {
  rule_name      = "${var.name_prefix}-bss"
  priority       = 1000
  reservoir_size = 1
  fixed_rate     = var.xray_sampling_rate
  host           = "*"
  http_method    = "*"
  service_name   = "*"
  service_type   = "*"
  url_path       = "*"
  resource_arn   = "*"
  version        = 1
}

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

# B-33: the GitHub OIDC provider + CI/CD deployer role USED to live here, created once per
# environment with `enable_github_oidc = true` in dev only. That's an account-level resource
# (there's only ever ONE "token.actions.githubusercontent.com" OIDC provider per AWS account —
# creating it a second time errors) masquerading as a per-environment one; it also meant "destroy
# dev nightly" would destroy the ONLY role every environment's CD depends on. Moved to
# environments/shared/main.tf (see B-34 there too — access entries into each cluster) — this
# module is now purely "per-service IRSA roles", matching its own docstring at the top of the
# file.

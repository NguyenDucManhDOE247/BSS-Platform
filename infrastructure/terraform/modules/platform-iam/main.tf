# IAM roles for CLUSTER ADDONS (not application services — see modules/iam for those).
#
# B-35: the eks module's docstring used to claim "this module sets up the IAM role Karpenter
# needs" — it never did, and platform/README.md already referenced an
# `aws_lb_controller_role_arn` Terraform output that didn't exist anywhere. Every addon in
# platform/ that talks to the AWS API needs its own IRSA role, same pattern as modules/iam uses
# for application services:
#   - AWS Load Balancer Controller (creates ALBs/NLBs from Ingress/Service resources)
#   - EBS CSI Driver (provisions the gp3 volumes Prometheus/Grafana/Alertmanager PVCs need — B-41)
#
# Deliberately NOT here yet (checklist scope for Giai đoạn 4 — see learning/20 mục Giai đoạn 4
# item 6): Karpenter (+ SQS spot-interruption queue), Fluent Bit, OTel Collector. Add them here
# the same way when their phase comes, instead of a new module each time.

data "aws_partition" "current" {}

locals {
  oidc_trust_condition = {
    StringEquals = {
      "${var.cluster_oidc_provider_url}:aud" = "sts.amazonaws.com"
    }
  }
}

# ── AWS Load Balancer Controller ────────────────────────────────────────
resource "aws_iam_role" "alb_controller" {
  name = "${var.name_prefix}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.cluster_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = merge(local.oidc_trust_condition.StringEquals, {
          "${var.cluster_oidc_provider_url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        })
      }
    }]
  })

  tags = var.tags
}

# The official policy is long (~20 statements covering ELBv2, EC2 SG/tag, ACM, Cognito, WAF,
# Shield) and changes with each controller release — hand-maintaining a copy here would silently
# go stale exactly like B-36's hardcoded RDS/EKS versions did. Fetched from the same place the
# project's own install docs point at (platform/README.md), pinned to the SAME chart/app version
# that README's `helm upgrade --install ... --version` installs — the two pins MUST move
# together (mismatched controller binary vs. IAM policy version is exactly the kind of "chạy 1
# lần thì được, sai ở apply thật" gap this project has hit before — see B-36's lesson in
# learning/nhat-ky-hoc-tap.md). Giai đoạn 5: bumped v2.13.0 → v3.5.0 (latest stable as of
# 2026-09-23, checked via `helm search repo eks/aws-load-balancer-controller --versions`) — like
# engine_version/k8s_version elsewhere in this repo, this WILL go stale again; re-check before
# every from-scratch dev apply.
data "http" "alb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json"
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "controller"
  role   = aws_iam_role.alb_controller.id
  policy = data.http.alb_controller_policy.response_body
}

# ── EBS CSI Driver ───────────────────────────────────────────────────────
# Unlike the ALB Controller, this one has a stable AWS-managed policy — no need to fetch/embed
# our own copy.
resource "aws_iam_role" "ebs_csi" {
  name = "${var.name_prefix}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.cluster_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = merge(local.oidc_trust_condition.StringEquals, {
          "${var.cluster_oidc_provider_url}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        })
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

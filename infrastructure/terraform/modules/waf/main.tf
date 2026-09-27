# Giai đoạn 7 / việc 7: AWS WAF in front of the ALB.
#
# REGIONAL scope (not CLOUDFRONT) because this attaches to an ALB, not a CloudFront distribution —
# LỚP 2 in CLAUDE.md is "CloudFront → ALB → AWS WAF" as a diagram, but there's no CloudFront
# distribution anywhere in this repo yet (deferred with the rest of the domain/HTTPS work — see
# memory bss-platform-phase0-decisions item 4), so today WAF sits directly on the ALB.
#
# The ALB itself is NOT a Terraform resource in this repo — the AWS Load Balancer Controller
# creates/destroys it dynamically from the `Ingress` object (see infrastructure/kubernetes/base/
# ingress.yaml). That controller natively supports a `alb.ingress.kubernetes.io/wafv2-acl-arn`
# annotation to associate a Web ACL with the ALB it manages — no `aws_wafv2_web_acl_association`
# resource needed/possible here (its `resource_arn` would have to be the ALB's ARN, which Terraform
# never learns since it didn't create the ALB). See scripts/wire-waf.sh for how the ARN below gets
# onto the live Ingress after `kubectl apply -k`.

resource "aws_wafv2_web_acl" "this" {
  name        = "${var.name_prefix}-waf"
  description = "Perimeter WAF for the ${var.name_prefix} ALB - managed rule groups + rate limit"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Priority 1-2: AWS-managed rule groups. Free to use (no extra $ beyond the WebACL/rule
  # baseline), maintained by AWS, cover the OWASP-style basics CLAUDE.md §10 asks for without this
  # project having to hand-write and maintain its own signature set.
  rule {
    name     = "aws-common-rule-set"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-sqli-rule-set"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-sqli-rule-set"
      sampled_requests_enabled   = true
    }
  }

  # Priority 4: our own rule — per-IP rate limit, protects against brute-force/scraping that the
  # managed rule groups above don't cover (they're pattern/signature based, not volumetric).
  rule {
    name     = "rate-limit-per-ip"
    priority = 4

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

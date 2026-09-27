output "web_acl_arn" {
  description = "Pass this to the ALB via the Ingress annotation alb.ingress.kubernetes.io/wafv2-acl-arn (see scripts/wire-waf.sh — the ALB itself is created by the AWS Load Balancer Controller, not Terraform, so there's no ALB resource here to attach this to directly)"
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  value = aws_wafv2_web_acl.this.id
}

output "web_acl_name" {
  value = aws_wafv2_web_acl.this.name
}

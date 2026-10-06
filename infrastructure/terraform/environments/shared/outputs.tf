output "ecr_registry_id" {
  value = module.ecr.registry_id
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "deployer_role_arns" {
  description = "Environment name (dev|staging|prod) -> its GitHub Actions deployer role ARN. Each environment's own state reads only its own entry (EKS access entry); scripts/setup-github-environments.sh puts each one into the matching GitHub Environment's AWS_ROLE_ARN variable."
  value       = { for k, r in aws_iam_role.deployer : k => r.arn }
}

# ── Tên miền (B-23, ADR-012) ──
output "dns_zone_id" {
  description = "Route 53 hosted zone id — các môi trường đọc để cấp quyền cho ExternalDNS (null nếu domain_name = \"\")"
  value       = one(aws_route53_zone.main[*].zone_id)
}

output "dns_zone_name" {
  value = one(aws_route53_zone.main[*].name)
}

output "dns_name_servers" {
  description = "4 NS phải nhập vào DigitalPlat (\"Use other nameservers\")"
  value       = one(aws_route53_zone.main[*].name_servers)
}

output "acm_certificate_arn" {
  description = "Cert apex + wildcard. ALB Controller tự tìm cert theo host của Ingress nên overlay không cần ARN này."
  value       = one(aws_acm_certificate.main[*].arn)
}
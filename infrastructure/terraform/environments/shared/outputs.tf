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

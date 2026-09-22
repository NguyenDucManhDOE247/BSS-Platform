output "ecr_registry_id" {
  value = module.ecr.registry_id
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "deployer_nonprod_role_arn" {
  value = aws_iam_role.deployer_nonprod.arn
}

output "deployer_prod_role_arn" {
  value = aws_iam_role.deployer_prod.arn
}

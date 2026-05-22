output "service_role_arns" {
  value = { for k, v in aws_iam_role.service : k => v.arn }
}

output "github_deployer_role_arn" {
  value = try(aws_iam_role.github_actions_deployer[0].arn, null)
}

output "service_role_arns" {
  value = { for k, v in aws_iam_role.service : k => v.arn }
}

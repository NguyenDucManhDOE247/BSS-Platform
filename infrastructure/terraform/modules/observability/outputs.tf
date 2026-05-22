output "application_log_group_name" {
  value = aws_cloudwatch_log_group.application.name
}

output "dataplane_log_group_name" {
  value = aws_cloudwatch_log_group.dataplane.name
}

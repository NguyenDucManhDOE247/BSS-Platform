output "project_name" {
  value       = aws_codebuild_project.runner.name
  description = "Dùng trong workflow: runs-on: codebuild-<project_name>-<run_id>-<run_attempt>"
}

output "project_arn" {
  value = aws_codebuild_project.runner.arn
}

output "security_group_id" {
  value = aws_security_group.runner.id
}

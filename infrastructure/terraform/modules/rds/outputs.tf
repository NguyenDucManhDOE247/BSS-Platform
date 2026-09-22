output "endpoint" {
  value = aws_db_instance.this.endpoint
}

output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "database_name" {
  value = aws_db_instance.this.db_name
}

output "master_secret_arn" {
  value     = aws_secretsmanager_secret.db_master.arn
  sensitive = false
}

output "security_group_id" {
  value = aws_security_group.rds.id
}

output "service_secret_arns" {
  description = "B-21: one Secrets Manager ARN per service (customer-service, product-catalog, order-management, billing-service) — each {username, password, host, port, dbname}"
  value       = { for k, v in aws_secretsmanager_secret.service : k => v.arn }
}

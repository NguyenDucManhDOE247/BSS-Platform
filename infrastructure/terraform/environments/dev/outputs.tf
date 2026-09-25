output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_registry" {
  value = "${data.terraform_remote_state.shared.outputs.ecr_registry_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = data.terraform_remote_state.shared.outputs.ecr_repository_urls
}

output "rds_endpoint" {
  value     = module.rds.endpoint
  sensitive = true
}

output "rds_master_secret_arn" {
  value = module.rds.master_secret_arn
}

output "service_db_secret_arns" {
  description = "B-21: per-service DB credential secrets — used by each service's SecretProviderClass (Giai đoạn 5)"
  value       = module.rds.service_secret_arns
}

output "event_bus_name" {
  value = module.eventbridge.event_bus_name
}

output "service_role_arns" {
  value = module.iam.service_role_arns
}

output "github_deployer_role_arn" {
  description = "Convenience mirror of environments/shared's output — the role for the GitHub Environment `dev` (variable AWS_ROLE_ARN)."
  value       = data.terraform_remote_state.shared.outputs.deployer_role_arns["dev"]
}

output "aws_lb_controller_role_arn" {
  description = "B-35: matches the output name platform/README.md's helm install command already expects"
  value       = module.platform_iam.alb_controller_role_arn
}

output "ebs_csi_role_arn" {
  value = module.platform_iam.ebs_csi_role_arn
}

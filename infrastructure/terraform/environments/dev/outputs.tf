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
  value = "${module.ecr.registry_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "rds_endpoint" {
  value     = module.rds.endpoint
  sensitive = true
}

output "rds_master_secret_arn" {
  value = module.rds.master_secret_arn
}

output "event_bus_name" {
  value = module.eventbridge.event_bus_name
}

output "service_role_arns" {
  value = module.iam.service_role_arns
}

output "github_deployer_role_arn" {
  value = module.iam.github_deployer_role_arn
}

output "aws_lb_controller_role_arn" {
  description = "B-35: matches the output name platform/README.md's helm install command already expects"
  value       = module.platform_iam.alb_controller_role_arn
}

output "ebs_csi_role_arn" {
  value = module.platform_iam.ebs_csi_role_arn
}

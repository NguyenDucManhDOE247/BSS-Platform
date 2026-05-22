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

output "rds_endpoint" {
  value     = module.rds.endpoint
  sensitive = true
}

output "event_bus_name" {
  value = module.eventbridge.event_bus_name
}

output "service_role_arns" {
  value = module.iam.service_role_arns
}

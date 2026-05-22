output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "cluster_oidc_provider_url" {
  value = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "node_instance_profile_name" {
  value = aws_iam_instance_profile.node.name
}

output "node_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

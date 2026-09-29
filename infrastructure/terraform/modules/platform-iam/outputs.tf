output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

output "ebs_csi_role_arn" {
  value = aws_iam_role.ebs_csi.arn
}

output "karpenter_role_arn" {
  value = var.enable_karpenter ? aws_iam_role.karpenter[0].arn : null
}

output "karpenter_interruption_queue" {
  value = var.enable_karpenter ? aws_sqs_queue.karpenter_interruption[0].name : null
}

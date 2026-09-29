# ── Karpenter (dọn nợ GĐ8, ADR-010 — thay ADR-007) ──────────────────────────────────────────────
# Bật bằng `enable_karpenter = true` (hiện chỉ dev). Dịch SÁT template CloudFormation chính thức của
# ĐÚNG phiên bản controller đang cài (v1.14.1 — `KARPENTER_VERSION` trong scripts/platform-install.sh):
#   https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.14.1/website/content/en/docs/getting-started/getting-started-with-karpenter/cloudformation.yaml
# Hai phiên bản PHẢI đi cùng nhau (cùng bài học với IAM policy của ALB Controller ở trên, B-36): nâng
# controller thì đối chiếu lại file này với template của phiên bản mới.
#
# Khác template: KHÔNG tạo node role riêng — node Karpenter dùng CHUNG role với managed node group
# (modules/eks `aws_iam_role.node`, đã có access entry EC2_LINUX do EKS tạo cho node group → node mới
# join cluster được ngay). Controller dùng IRSA như mọi addon khác trong repo (không Pod Identity).

locals {
  karpenter    = var.enable_karpenter ? 1 : 0
  kp_cluster   = var.cluster_name
  kp_partition = data.aws_partition.current.partition
  kp_region    = data.aws_region.current.name
  kp_account   = data.aws_caller_identity.current.account_id
  kp_ec2_arn   = "arn:${local.kp_partition}:ec2:${local.kp_region}"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "karpenter" {
  count = local.karpenter
  name  = "${var.name_prefix}-karpenter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.cluster_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = merge(local.oidc_trust_condition.StringEquals, {
          "${var.cluster_oidc_provider_url}:sub" = "system:serviceaccount:kube-system:karpenter"
        })
      }
    }]
  })

  tags = var.tags
}

# 1. NodeLifecyclePolicy — tạo/xóa EC2 CHỈ khi mang tag của cluster + nodepool (không đụng máy khác).
resource "aws_iam_role_policy" "karpenter_node_lifecycle" {
  count = local.karpenter
  name  = "node-lifecycle"
  role  = aws_iam_role.karpenter[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceAccessActions"
        Effect = "Allow"
        Resource = [
          "${local.kp_ec2_arn}::image/*",
          "${local.kp_ec2_arn}::snapshot/*",
          "${local.kp_ec2_arn}:*:security-group/*",
          "${local.kp_ec2_arn}:*:subnet/*",
          "${local.kp_ec2_arn}:*:capacity-reservation/*",
          "${local.kp_ec2_arn}:*:placement-group/*",
        ]
        Action = ["ec2:RunInstances", "ec2:CreateFleet"]
      },
      {
        Sid      = "AllowScopedEC2LaunchTemplateAccessActions"
        Effect   = "Allow"
        Resource = "${local.kp_ec2_arn}:*:launch-template/*"
        Action   = ["ec2:RunInstances", "ec2:CreateFleet"]
        Condition = {
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${local.kp_cluster}" = "owned" }
          StringLike   = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Resource = [
          "${local.kp_ec2_arn}:*:fleet/*",
          "${local.kp_ec2_arn}:*:instance/*",
          "${local.kp_ec2_arn}:*:volume/*",
          "${local.kp_ec2_arn}:*:network-interface/*",
          "${local.kp_ec2_arn}:*:launch-template/*",
          "${local.kp_ec2_arn}:*:spot-instances-request/*",
        ]
        Action = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${local.kp_cluster}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                      = local.kp_cluster
          }
          StringLike = { "aws:RequestTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Resource = [
          "${local.kp_ec2_arn}:*:fleet/*",
          "${local.kp_ec2_arn}:*:instance/*",
          "${local.kp_ec2_arn}:*:volume/*",
          "${local.kp_ec2_arn}:*:network-interface/*",
          "${local.kp_ec2_arn}:*:launch-template/*",
          "${local.kp_ec2_arn}:*:spot-instances-request/*",
        ]
        Action = "ec2:CreateTags"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${local.kp_cluster}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                      = local.kp_cluster
            "ec2:CreateAction"                                         = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
          }
          StringLike = { "aws:RequestTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Resource = "${local.kp_ec2_arn}:*:instance/*"
        Action   = "ec2:CreateTags"
        Condition = {
          StringEquals                = { "aws:ResourceTag/kubernetes.io/cluster/${local.kp_cluster}" = "owned" }
          StringLike                  = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
          StringEqualsIfExists        = { "aws:RequestTag/eks:eks-cluster-name" = local.kp_cluster }
          "ForAllValues:StringEquals" = { "aws:TagKeys" = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"] }
        }
      },
      {
        Sid      = "AllowScopedDeletion"
        Effect   = "Allow"
        Resource = ["${local.kp_ec2_arn}:*:instance/*", "${local.kp_ec2_arn}:*:launch-template/*"]
        Action   = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        Condition = {
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${local.kp_cluster}" = "owned" }
          StringLike   = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
        }
      },
    ]
  })
}

# 2. IAMIntegrationPolicy — truyền node role cho EC2 + tự quản instance profile (Karpenter v1 tự tạo).
resource "aws_iam_role_policy" "karpenter_iam_integration" {
  count = local.karpenter
  name  = "iam-integration"
  role  = aws_iam_role.karpenter[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowPassingInstanceRole"
        Effect    = "Allow"
        Resource  = var.node_role_arn
        Action    = "iam:PassRole"
        Condition = { StringEquals = { "iam:PassedToService" = ["ec2.amazonaws.com", "ec2.amazonaws.com.cn"] } }
      },
      {
        Sid      = "AllowScopedInstanceProfileCreationActions"
        Effect   = "Allow"
        Resource = "arn:${local.kp_partition}:iam::${local.kp_account}:instance-profile/*"
        Action   = ["iam:CreateInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${local.kp_cluster}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                      = local.kp_cluster
            "aws:RequestTag/topology.kubernetes.io/region"             = local.kp_region
          }
          StringLike = { "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*" }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileTagActions"
        Effect   = "Allow"
        Resource = "arn:${local.kp_partition}:iam::${local.kp_account}:instance-profile/*"
        Action   = ["iam:TagInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${local.kp_cluster}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = local.kp_region
            "aws:RequestTag/kubernetes.io/cluster/${local.kp_cluster}"  = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                       = local.kp_cluster
            "aws:RequestTag/topology.kubernetes.io/region"              = local.kp_region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"  = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileActions"
        Effect   = "Allow"
        Resource = "arn:${local.kp_partition}:iam::${local.kp_account}:instance-profile/*"
        Action   = ["iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${local.kp_cluster}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = local.kp_region
          }
          StringLike = { "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*" }
        }
      },
    ]
  })
}

# 3–6. EKS discovery + interruption queue + zonal shift + đọc tài nguyên (Describe*, giá, AMI SSM).
resource "aws_iam_role_policy" "karpenter_integration" {
  count = local.karpenter
  name  = "eks-interruption-discovery"
  role  = aws_iam_role.karpenter[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowAPIServerEndpointDiscovery"
        Effect   = "Allow"
        Resource = "arn:${local.kp_partition}:eks:${local.kp_region}:${local.kp_account}:cluster/${local.kp_cluster}"
        Action   = "eks:DescribeCluster"
      },
      {
        Sid      = "AllowInterruptionQueueActions"
        Effect   = "Allow"
        Resource = aws_sqs_queue.karpenter_interruption[0].arn
        Action   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
      },
      {
        Sid       = "AllowZonalShiftStatusReadOnly"
        Effect    = "Allow"
        Resource  = "*"
        Action    = ["arc-zonal-shift:GetManagedResource"]
        Condition = { StringEquals = { "arc-zonal-shift:ResourceIdentifier" = "arn:${local.kp_partition}:eks:${local.kp_region}:${local.kp_account}:cluster/${local.kp_cluster}" } }
      },
      {
        Sid      = "AllowRegionalReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action = [
          "ec2:DescribeCapacityReservations", "ec2:DescribeImages", "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus", "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates", "ec2:DescribePlacementGroups", "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory", "ec2:DescribeSubnets",
        ]
        Condition = { StringEquals = { "aws:RequestedRegion" = local.kp_region } }
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Resource = "arn:${local.kp_partition}:ssm:${local.kp_region}::parameter/aws/service/*"
        Action   = "ssm:GetParameter"
      },
      { Sid = "AllowPricingReadActions", Effect = "Allow", Resource = "*", Action = "pricing:GetProducts" },
      { Sid = "AllowUnscopedInstanceProfileListAction", Effect = "Allow", Resource = "*", Action = "iam:ListInstanceProfiles" },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Resource = "arn:${local.kp_partition}:iam::${local.kp_account}:instance-profile/*"
        Action   = "iam:GetInstanceProfile"
      },
    ]
  })
}

# ── Hàng đợi interruption: EventBridge đẩy cảnh báo Spot sắp bị thu hồi (2 phút), rebalance, health,
#    đổi trạng thái instance → Karpenter chủ động "cordon + drain + thay node" TRƯỚC khi máy biến mất.
resource "aws_sqs_queue" "karpenter_interruption" {
  count                     = local.karpenter
  name                      = local.kp_cluster
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  count     = local.karpenter
  queue_url = aws_sqs_queue.karpenter_interruption[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "EC2InterruptionPolicy"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption[0].arn
      },
      {
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.karpenter_interruption[0].arn
        Condition = { Bool = { "aws:SecureTransport" = false } }
      },
    ]
  })
}

locals {
  karpenter_event_rules = var.enable_karpenter ? {
    scheduled-change          = { source = "aws.health", detail_type = "AWS Health Event" }
    spot-interruption         = { source = "aws.ec2", detail_type = "EC2 Spot Instance Interruption Warning" }
    rebalance                 = { source = "aws.ec2", detail_type = "EC2 Instance Rebalance Recommendation" }
    instance-state-change     = { source = "aws.ec2", detail_type = "EC2 Instance State-change Notification" }
    capacity-reservation-intr = { source = "aws.ec2", detail_type = "EC2 Capacity Reservation Instance Interruption Warning" }
  } : {}
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each = local.karpenter_event_rules
  name     = "${var.name_prefix}-karpenter-${each.key}"
  event_pattern = jsonencode({
    source        = [each.value.source]
    "detail-type" = [each.value.detail_type]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each  = local.karpenter_event_rules
  rule      = aws_cloudwatch_event_rule.karpenter[each.key].name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption[0].arn
}

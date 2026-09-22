# EKS cluster with managed node groups (1 group: "system") and IRSA prep.
#
# Karpenter is installed via Helm in a separate step (see platform/karpenter/).
# This module sets up the node IAM role Karpenter-provisioned nodes will assume (they reuse
# the "node" role below, tagged for Karpenter's subnet/SG discovery). It does NOT set up
# Karpenter's own controller IAM role — B-35: that (and the AWS Load Balancer Controller's,
# and the EBS CSI Driver's) lives in modules/platform-iam, added when each addon's phase comes.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ── EKS cluster ────────────────────────────────────────────────────────
resource "aws_iam_role" "cluster" {
  name = "${var.name_prefix}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# AWS-0039: envelope-encrypt Kubernetes Secrets (etcd) with a customer-managed key, on top of the
# encryption-at-rest AWS already provides by default. Cheap (a few cents/month) and has no
# behavioral impact on the cluster — safe to turn on unconditionally rather than deferring it.
resource "aws_kms_key" "eks_secrets" {
  description             = "${var.name_prefix} EKS Kubernetes Secrets envelope encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = var.tags
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.name_prefix}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.k8s_version

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    # AWS-0040/AWS-0041 (dev): a static scanner can't see the tfvars value applied at `plan`
    # time, so it always assumes the worst case for a CIDR-typed variable. `public_access_cidrs`
    # defaults to 0.0.0.0/0 ONLY in dev on purpose (CLAUDE.md §4: dev is a $0, nightly-destroyed
    # learning cluster with no fixed office/home IP to pin to yet) — staging and prod require an
    # explicit value with no permissive default (see their own variables.tf), so this is a
    # documented, reviewed trade-off for dev specifically, not an oversight.
    #trivy:ignore:AVD-AWS-0040
    endpoint_public_access = true
    #trivy:ignore:AVD-AWS-0041
    public_access_cidrs = var.public_access_cidrs
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = var.cluster_log_types

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy]
}

# ── OIDC provider for IRSA ─────────────────────────────────────────────
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = var.tags
}

# ── Node IAM role (used by both managed node group + Karpenter nodes) ──
resource "aws_iam_role" "node" {
  name = "${var.name_prefix}-eks-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name_prefix}-eks-node"
  role = aws_iam_role.node.name
}

# ── Managed node group: minimum capacity for system pods ──────────────
# Karpenter will provision additional nodes on demand for workloads.
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.system_node_instance_types
  capacity_type  = "ON_DEMAND" # system pods don't tolerate spot interruption

  scaling_config {
    desired_size = var.system_node_desired_size
    min_size     = var.system_node_min_size
    max_size     = var.system_node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "system"
  }

  tags = merge(var.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })

  depends_on = [aws_iam_role_policy_attachment.node_policies]
}

# ── SG tag Karpenter requires for node discovery ───────────────────────
# Subnet tagging for Karpenter lives in modules/vpc (on aws_subnet.private's own `tags` block)
# instead of a separate aws_ec2_tag resource here — see the comment there for why: found by
# actually applying to real AWS, a separate `aws_ec2_tag` resource fights with the subnet
# resource's own authoritative `tags` on every apply. The cluster security group below doesn't
# have that problem — nothing else in this config manages ITS tags, so no tug-of-war.
resource "aws_ec2_tag" "cluster_sg_karpenter" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# ── EKS Add-ons ────────────────────────────────────────────────────────
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"
}

# B-35/B-39/B-41: "aws-ebs-csi-driver" addon moved to each environment's own main.tf, NOT here.
# It needs `service_account_role_arn` from modules/platform-iam, which itself needs THIS
# module's `cluster_oidc_provider_arn`/`_url` outputs — wiring the addon in here too would make
# module "eks" and module "platform_iam" depend on each other (a cycle Terraform refuses to
# plan). The environment's main.tf is the one place that already sees both modules' outputs.

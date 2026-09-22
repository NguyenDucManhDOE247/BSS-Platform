# VPC for the BSS platform.
#
# Layout per AZ:
#   - 1 public subnet  (for ALB)
#   - 1 private subnet (for EKS nodes + RDS)
#
# Cost-conscious defaults:
#   - enable_nat_gateway defaults to false but every environment (incl. dev) sets it to true —
#     see docs/adr/ADR-002-mang-dev.md for why "no NAT, VPC endpoints only" doesn't actually work
#     for a private-subnet EKS cluster (Helm charts pull from quay.io/registry.k8s.io/docker.io,
#     which no VPC endpoint can reach).
#   - enable_interface_endpoints stays off everywhere; only the free S3 gateway endpoint is
#     always on.
#
# Cluster discovery tags are required so the AWS Load Balancer Controller
# can find subnets when creating ALBs/NLBs.

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  # Public subnet by design (ALB/NAT Gateway live here — see CLAUDE.md §2); every other
  # workload sits in the private subnets below, which don't set this.
  map_public_ip_on_launch = true # trivy:ignore:AVD-AWS-0164

  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ── NAT Gateway (optional, expensive: ~$33/month per gateway) ──────────
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-eip"
  })
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.this]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat"
  })
}

# ── Route tables ───────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[0].id
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── S3 Gateway endpoint — ALWAYS on, it's free and has no AZ multiplier ──
# ECR stores image layers on S3, so this helps even when a NAT Gateway is also
# in place (fewer bytes billed through the NAT's per-GB data charge).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-s3" })
}

# ── Interface (PrivateLink) endpoints — opt-in, see ADR-002 ───────────
# Costed per-endpoint PER-AZ (~$0.013/h each) — NOT a substitute for a NAT
# Gateway on their own (see var.enable_interface_endpoints doc).
resource "aws_security_group" "vpc_endpoints" {
  count       = var.enable_interface_endpoints ? 1 : 0
  name        = "${var.name_prefix}-vpce-sg"
  description = "Allow HTTPS from VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  # AWS-0104: egress-all is intentionally broad here — interface endpoints are the thing PODS
  # reach to talk to AWS APIs (ECR, Secrets Manager, CloudWatch Logs, STS), so locking this down
  # to specific ports/destinations belongs with the NetworkPolicy default-deny work already
  # planned for Phase 9 (CLAUDE.md §8), not a one-off SG tweak here.
  #trivy:ignore:AVD-AWS-0104
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = var.enable_interface_endpoints ? toset(["ecr.api", "ecr.dkr", "secretsmanager", "logs", "sts"]) : []
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-${each.key}" })
}

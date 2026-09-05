data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

# Resolves a role session's ephemeral STS ARN to the durable IAM role that
# issued it; passes plain user/role ARNs through unchanged.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }

  dynamic "filter" {
    for_each = var.region == "us-east-1" ? [1] : []
    content {
      name   = "zone-name"
      values = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]
    }
  }
}

# Skipped entirely in BYO VPC mode — network.tf carves the same subnet layout
# inside the existing VPC and normalizes both paths onto one set of locals.
moved {
  from = module.vpc
  to   = module.vpc[0]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.14.0"

  count = local.byo_enabled ? 0 : 1

  name            = "ryvn-${var.environment_name}-vpc"
  cidr            = var.vpc_cidr
  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # needed for EKS cluster setup
  map_public_ip_on_launch = true

  # VPC Flow Logs configuration
  enable_flow_log                      = var.enable_flow_log
  create_flow_log_cloudwatch_iam_role  = var.enable_flow_log
  create_flow_log_cloudwatch_log_group = var.enable_flow_log

  # Tags required for EKS and Karpenter
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = 1
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = 1
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "karpenter.sh/discovery"                      = local.cluster_name
  }

  tags = local.tags
}

# Transit Gateway subnets (separate from VPC module since it doesn't support them natively)
resource "aws_subnet" "transit_gateway" {
  count             = length(local.tgw_subnets)
  vpc_id            = local.vpc_id
  cidr_block        = local.tgw_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name = "ryvn-${var.environment_name}-tgw-${count.index + 1}"
    Type = "TransitGateway"
  })
}

# Route table for Transit Gateway subnets
resource "aws_route_table" "transit_gateway" {
  count  = length(local.tgw_subnets) > 0 ? 1 : 0
  vpc_id = local.vpc_id

  tags = merge(local.tags, {
    Name = "ryvn-${var.environment_name}-tgw-rt"
  })
}

# Associate Transit Gateway subnets with their route table
resource "aws_route_table_association" "transit_gateway" {
  count          = length(aws_subnet.transit_gateway)
  subnet_id      = aws_subnet.transit_gateway[count.index].id
  route_table_id = aws_route_table.transit_gateway[0].id
}

# Local values
locals {
  # Raw cluster name before length optimization
  raw_cluster_name = "ryvn-eks-${var.environment_name}"

  # Smart cluster name: if over 36 chars, use "ryvn-" instead of "ryvn-eks-" and trim to 36
  cluster_name = length(local.raw_cluster_name) <= 36 ? local.raw_cluster_name : substr(
    replace(local.raw_cluster_name, "ryvn-eks-", "ryvn-"),
    0,
    36
  )

  azs = slice(data.aws_availability_zones.available.names, 0, 3)
  # Auto-calculate Transit Gateway subnets if enabled but no custom CIDRs provided
  # Uses /28 subnets (16 IPs, 14 usable) starting from netnum 4080 to avoid conflicts
  # Existing allocations: 0-2 (private /20), 48-50 (public /24), 52-54 (intra /24)
  auto_tgw_subnets = var.enable_transit_gateway_subnets && length(var.transit_gateway_subnets) == 0 ? [
    for k, v in local.azs : cidrsubnet(var.vpc_cidr, 12, k + 4080) # /28 subnets at end of address space
  ] : []

  # Use custom CIDRs if provided, otherwise use auto-calculated ones
  tgw_subnets = length(var.transit_gateway_subnets) > 0 ? var.transit_gateway_subnets : local.auto_tgw_subnets

  partition = data.aws_partition.current.partition

  # Durable ARN of the identity executing Terraform — RyvnAccessRole when the
  # Ryvn control plane provisions, the operator's own role or user otherwise.
  executor_principal_arn = data.aws_iam_session_context.current.issuer_arn

  # Extract OIDC provider URL from ARN, handling any partition (aws, aws-us-gov, aws-cn)
  oidc_provider_url = replace(module.eks.oidc_provider_arn, "/^arn:[^:]+:iam::\\d+:oidc-provider\\//", "")

  tags = {
    Environment = var.environment_name
    Terraform   = "true"
    Cluster     = local.cluster_name
  }
}

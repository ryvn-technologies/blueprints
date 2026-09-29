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
  version = "5.21.0"

  count = local.byo_enabled ? 0 : 1

  name            = "ryvn-${var.environment_name}-vpc"
  cidr            = var.vpc_cidr
  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]

  enable_nat_gateway     = !local.firewall_enabled
  single_nat_gateway     = !local.firewall_enabled
  one_nat_gateway_per_az = local.firewall_enabled
  # The private default route is aws_route.private_default below in both modes.
  create_private_nat_gateway_route = false
  enable_dns_hostnames             = true
  enable_dns_support               = true

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

moved {
  from = module.vpc[0].aws_route.private_nat_gateway[0]
  to   = aws_route.private_default["0"]
}

# One owner for the private tables' 0.0.0.0/0 route in both firewall modes.
# Disabled: the single NAT table (index 0) routes to the VPC module's NAT
# gateway. Enabled: each AZ table routes to that AZ's firewall endpoint.
# Switching modes therefore replaces the target of route "0" in place
# (ec2:ReplaceRoute) instead of destroying one route resource and creating
# another for the same destination, which cannot be ordered and fails with
# RouteAlreadyExists. Keyed by AZ index so the disabled-mode legacy address
# stays stable.
resource "aws_route" "private_default" {
  for_each = local.byo_enabled ? {} : { for i, az in local.azs : tostring(i) => az if local.firewall_enabled || i == 0 }

  route_table_id         = module.vpc[0].private_route_table_ids[tonumber(each.key)]
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = local.firewall_enabled ? null : module.vpc[0].natgw_ids[0]
  vpc_endpoint_id        = local.firewall_enabled ? module.egress_network[0].firewall_endpoint_ids[each.value] : null

  timeouts {
    create = "5m"
  }
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

# No internal-elb tag, so load balancers stay on the first subnets.
# The cni tag lets the VPC CNI give existing nodes pod IPs from these subnets.
resource "aws_subnet" "additional_workload" {
  for_each          = local.additional_workload_subnets
  vpc_id            = local.vpc_id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.availability_zone

  tags = merge(local.tags, {
    Name                                          = "ryvn-${var.environment_name}-vpc-private-${each.key}"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "karpenter.sh/discovery"                      = local.cluster_name
    "kubernetes.io/role/cni"                      = "1"
  })
}

resource "aws_route_table_association" "additional_workload" {
  for_each       = local.additional_workload_subnets
  subnet_id      = aws_subnet.additional_workload[each.key].id
  route_table_id = element(flatten(module.vpc[*].private_route_table_ids), each.value.az_index)
}

# Blocks lowering the count, which would cut subnets in use off from the NAT gateway.
# Filtered by the Cluster tag instead of the VPC ID so it works before the VPC exists.
data "aws_subnets" "workload_subnets_above_count" {
  count = length(local.workload_subnet_cidrs_above_count) > 0 ? 1 : 0

  filter {
    name   = "cidr-block"
    values = local.workload_subnet_cidrs_above_count
  }

  filter {
    name   = "tag:Cluster"
    values = [local.cluster_name]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) == 0
      error_message = "workload_subnets_per_az can't be lowered. Set it back to its previous value."
    }
  }
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

  # Of the VPC's 16 equal blocks, module.vpc uses 0-3 and auto TGW subnets sit in 15, so 4-12 are free.
  additional_workload_subnet_slots = flatten([
    for n in range(2, 5) : [
      for k, az in local.azs : {
        key               = "${az}-${n}"
        position_in_az    = n
        az_index          = k
        availability_zone = az
        cidr_block        = cidrsubnet(var.vpc_cidr, 4, 4 + 3 * (n - 2) + k)
      }
    ]
  ])
  additional_workload_subnets = local.byo_enabled ? {} : {
    for slot in local.additional_workload_subnet_slots : slot.key => slot if slot.position_in_az <= var.workload_subnets_per_az
  }
  workload_subnet_cidrs_above_count = local.byo_enabled ? [] : [
    for slot in local.additional_workload_subnet_slots : slot.cidr_block if slot.position_in_az > var.workload_subnets_per_az
  ]

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

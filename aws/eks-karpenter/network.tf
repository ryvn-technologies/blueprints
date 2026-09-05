# ============================================================================
# BYO VPC — carve mode and subnets mode
# ============================================================================
# When existing_vpc_id is set, module.vpc is skipped and one of two modes
# supplies the network:
#
#   carve mode (default) — Ryvn carves its standard subnet layout inside the
#   existing VPC using the same cidrsubnet math the Ryvn-provisioned path
#   uses. Ryvn creates and owns the route tables for the subnets it creates; it
#   never modifies a route table that already exists in the VPC.
#
#   subnets mode — the caller passes existing_workload_subnet_ids (and
#   optionally control-plane/public lists) and Ryvn creates *zero* network
#   topology: no subnets, no route tables, no routes, no associations, no NAT,
#   no tags on anything it does not own. Routing is entirely the network
#   authority's. This is the mode for accounts where a central authority owns
#   the network and denies topology mutation by SCP: landing zones with a hard
#   network-team boundary, RAM-shared VPCs, and similar.
#
# All BYO conditionals live in this file. Everything downstream (eks.tf,
# dns.tf, outputs.tf) reads the normalized locals at the bottom, so no other
# file learns whether the VPC is Ryvn-provisioned or pre-existing, or which mode made
# the subnets.

locals {
  byo_enabled = var.existing_vpc_id != null && var.existing_vpc_id != ""

  # Presence of the workload subnet list is the mode switch, mirroring how the
  # presence of existing_vpc_id switches VPC ownership. No separate flag: a
  # flag and a list can disagree, and there is nothing subnets mode can mean
  # without the IDs.
  byo_subnets_enabled = local.byo_enabled && length(var.existing_workload_subnet_ids) > 0
  byo_carve_enabled   = local.byo_enabled && !local.byo_subnets_enabled

  # Public subnets — and therefore an internet gateway — only exist when Ryvn
  # creates the NAT itself. transit_gateway and nat_gateway egress are
  # internal-only: centralized-egress accounts typically deny IGW creation by
  # SCP, and a pre-existing NAT lives in public subnets Ryvn does not own.
  # create_nat is rejected outright in subnets mode (a NAT needs a public
  # subnet and a route Ryvn is not allowed to create), so this stays carve-only.
  byo_public_enabled = local.byo_carve_enabled && var.egress_mode == "create_nat"
}

# ----------------------------------------------------------------------------
# Discovery of the existing VPC
# ----------------------------------------------------------------------------

data "aws_vpc" "existing" {
  count = local.byo_enabled ? 1 : 0
  id    = var.existing_vpc_id
}

data "aws_security_group" "existing_default" {
  count  = local.byo_enabled ? 1 : 0
  vpc_id = var.existing_vpc_id
  name   = "default"
}

# Every subnet already in the VPC. The carve must not overlap any of them —
# most importantly pre-existing TGW attachment subnets, which may sit
# anywhere in the range (LZA layouts commonly place them at the head, not the
# tail our Ryvn-provisioned TGW math assumes). After the first apply this list
# also contains the subnets Ryvn itself carved; those are excluded by tag in
# byo_foreign_subnets below, or every later plan would flag the carve as
# overlapping itself and block all day-2 applies.
data "aws_subnets" "existing" {
  count = local.byo_carve_enabled ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [var.existing_vpc_id]
  }
}

data "aws_subnet" "existing" {
  for_each = toset(flatten(data.aws_subnets.existing[*].ids))
  id       = each.value
}

# ----------------------------------------------------------------------------
# Egress target discovery
# ----------------------------------------------------------------------------

# A TGW attachment only carries traffic from AZs where it has an ENI. An AZ the
# attachment does not cover blackholes egress silently once nodes come up, so
# the AZs of the attachment's subnets are validated against the carve below.
# The state filter makes a pending or failed attachment fail here at plan time
# ("no matching attachment") — routes to a TGW only work once the attachment is
# available, so it must be created before Ryvn provisions.
data "aws_ec2_transit_gateway_vpc_attachment" "existing" {
  count = local.byo_enabled && var.egress_mode == "transit_gateway" && var.egress_target_id != null ? 1 : 0

  filter {
    name   = "transit-gateway-id"
    values = [var.egress_target_id]
  }

  filter {
    name   = "vpc-id"
    values = [var.existing_vpc_id]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

data "aws_subnet" "tgw_attachment" {
  for_each = toset(flatten(data.aws_ec2_transit_gateway_vpc_attachment.existing[*].subnet_ids))
  id       = each.value
}

# Resolves the egress IP for a pre-existing NAT so it can be reported
# it. Under transit_gateway egress there is no in-VPC NAT and the egress IPs
# live in another account — reported as unknown, never as empty.
# Scoped to the VPC and to available state: a route can only target a NAT in
# the same VPC, so a NAT elsewhere in the account must fail here at plan time
# rather than at route creation.
data "aws_nat_gateway" "existing" {
  count  = local.byo_enabled && var.egress_mode == "nat_gateway" && var.egress_target_id != null ? 1 : 0
  id     = var.egress_target_id
  vpc_id = var.existing_vpc_id
  state  = "available"
}

data "aws_internet_gateway" "existing" {
  count = local.byo_public_enabled ? 1 : 0

  filter {
    name   = "attachment.vpc-id"
    values = [var.existing_vpc_id]
  }
}

# ----------------------------------------------------------------------------
# Carve computation
# ----------------------------------------------------------------------------

locals {
  byo_vpc_cidr = one(data.aws_vpc.existing[*].cidr_block)

  # Same layout as the Ryvn-provisioned path (main.tf): workload subnets at
  # VPC+4 bits from netnum 0, control-plane at VPC+8 from netnum 52, public at
  # VPC+8 from netnum 48. Carve-mode environments are therefore structurally
  # identical to Ryvn-provisioned ones.
  #
  # These defaults assume the head of the range is free. When it is not — the
  # common landing-zone case — free blocks are passed in explicitly via
  # byo_*_subnet_cidrs. The overlap precondition below is what turns a bad
  # default into a pre-apply error instead of a mid-apply AWS conflict.
  byo_default_workload_cidrs = local.byo_vpc_cidr == null ? [] : [
    for k in range(length(local.azs)) : cidrsubnet(local.byo_vpc_cidr, 4, k)
  ]
  byo_default_control_plane_cidrs = local.byo_vpc_cidr == null ? [] : [
    for k in range(length(local.azs)) : cidrsubnet(local.byo_vpc_cidr, 8, k + 52)
  ]
  byo_default_public_cidrs = local.byo_vpc_cidr == null ? [] : [
    for k in range(length(local.azs)) : cidrsubnet(local.byo_vpc_cidr, 8, k + 48)
  ]

  # Empty in subnets mode: nothing is carved, so every overlap, out-of-VPC and
  # AZ-coverage local below reduces to the empty set and its precondition
  # passes vacuously instead of judging a carve that will never happen.
  byo_workload_cidrs      = !local.byo_carve_enabled ? [] : (length(var.byo_workload_subnet_cidrs) > 0 ? var.byo_workload_subnet_cidrs : local.byo_default_workload_cidrs)
  byo_control_plane_cidrs = !local.byo_carve_enabled ? [] : (length(var.byo_control_plane_subnet_cidrs) > 0 ? var.byo_control_plane_subnet_cidrs : local.byo_default_control_plane_cidrs)
  byo_public_cidrs = !local.byo_public_enabled ? [] : (
    length(var.byo_public_subnet_cidrs) > 0 ? var.byo_public_subnet_cidrs : local.byo_default_public_cidrs
  )

  byo_planned_cidrs = concat(local.byo_workload_cidrs, local.byo_control_plane_cidrs, local.byo_public_cidrs)

  # Subnets in the VPC that Ryvn does not own. Ryvn's carved subnets all carry
  # the Cluster tag from local.tags; anything without it is pre-existing
  # (TGW attachment subnets included) and the carve must not touch it. AWS
  # subnet filters cannot express negation, so the exclusion happens here
  # rather than in data.aws_subnets.existing.
  byo_foreign_subnets = [
    for s in data.aws_subnet.existing : s
    if try(s.tags["Cluster"], "") != local.cluster_name
  ]

  # Overlap detection. HCL has no IP arithmetic, so each CIDR is reduced to an
  # integer [first, last] interval and compared pairwise. Two ranges overlap iff
  # each one's start falls at or before the other's end.
  byo_existing_ranges = [
    for s in local.byo_foreign_subnets : [
      sum([for i, o in split(".", cidrhost(s.cidr_block, 0)) : tonumber(o) * pow(256, 3 - i)]),
      sum([for i, o in split(".", cidrhost(s.cidr_block, -1)) : tonumber(o) * pow(256, 3 - i)]),
    ]
  ]
  byo_planned_ranges = [
    for c in local.byo_planned_cidrs : [
      sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)]),
      sum([for i, o in split(".", cidrhost(c, -1)) : tonumber(o) * pow(256, 3 - i)]),
    ]
  ]
  byo_overlapping_cidrs = [
    for i, p in local.byo_planned_ranges : local.byo_planned_cidrs[i]
    if anytrue([for e in local.byo_existing_ranges : p[0] <= e[1] && e[0] <= p[1]])
  ]

  # The roles are not independently placeable: the standard layout puts the
  # control-plane /24s at netnums 52-54, which fall *inside* the fourth workload
  # /20. Shifting the workload subnets to clear an occupied head of the range
  # therefore collides with the control-plane block unless it moves too. Without
  # this check that lands as an InvalidSubnet.Conflict mid-apply.
  byo_self_overlapping_cidrs = [
    for i, p in local.byo_planned_ranges : local.byo_planned_cidrs[i]
    if anytrue([for j, q in local.byo_planned_ranges : p[0] <= q[1] && q[0] <= p[1] if j != i])
  ]

  # Planned CIDRs that fall outside every CIDR association of the VPC. The
  # overlap checks above cannot catch these — a block outside the VPC overlaps
  # nothing — so without this they surface as an AWS error mid-apply.
  byo_vpc_association_ranges = !local.byo_carve_enabled ? [] : [
    for c in local.vpc_cidrs : [
      sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)]),
      sum([for i, o in split(".", cidrhost(c, -1)) : tonumber(o) * pow(256, 3 - i)]),
    ]
  ]
  byo_out_of_vpc_cidrs = [
    for i, p in local.byo_planned_ranges : local.byo_planned_cidrs[i]
    if !anytrue([for a in local.byo_vpc_association_ranges : a[0] <= p[0] && p[1] <= a[1]])
  ]

  # The AZs the carve actually places workload subnets in — subnet AZ
  # assignment is positional over local.azs. Egress coverage is judged against
  # these, not all region AZs: a 2-AZ carve does not need the attachment to
  # cover a third AZ it never uses. min() keeps the slice in bounds when the
  # caller passes too many CIDRs, so the length precondition can report that
  # properly instead of an index error here.
  byo_carve_azs = slice(local.azs, 0, min(length(local.byo_workload_cidrs), length(local.azs)))

  byo_tgw_attachment_azs = sort([for s in data.aws_subnet.tgw_attachment : s.availability_zone])
  byo_uncovered_azs = var.egress_mode == "transit_gateway" && length(data.aws_ec2_transit_gateway_vpc_attachment.existing) > 0 ? sort(setsubtract(
    toset(local.byo_subnets_enabled ? local.byo_provided_workload_azs : local.byo_carve_azs),
    toset(local.byo_tgw_attachment_azs)
  )) : []
}

# ----------------------------------------------------------------------------
# BYO subnets mode — discovery of the caller-provided subnets
# ----------------------------------------------------------------------------
# Read-only. These lookups are the whole of the mode's AWS interaction on the
# network side: they resolve the AZ, CIDR and free-IP count the preconditions
# and the normalized contract need. Ryvn creates nothing here.

data "aws_subnet" "byo_provided_workload" {
  for_each = local.byo_subnets_enabled ? toset(var.existing_workload_subnet_ids) : []
  id       = each.value
}

# Defaults to the workload subnets when the caller gives no dedicated list —
# EKS accepts the same subnets for control-plane ENIs and nodes, and a
# centrally-managed network often has no spare tier to dedicate.
data "aws_subnet" "byo_provided_control_plane" {
  for_each = local.byo_subnets_enabled ? toset(local.byo_provided_control_plane_ids) : []
  id       = each.value
}

data "aws_subnet" "byo_provided_public" {
  for_each = local.byo_subnets_enabled ? toset(var.existing_public_subnet_ids) : []
  id       = each.value
}

# The route table actually governing each workload subnet — its explicit
# association, or the VPC's main route table when there is none. This is how a
# missing default route becomes a plan-time failure instead of nodes that come
# up and cannot reach ECR, EKS or the Ryvn control plane.
data "aws_route_table" "byo_provided_workload" {
  for_each  = local.byo_subnets_enabled ? toset(var.existing_workload_subnet_ids) : []
  subnet_id = each.value
}

locals {
  # Ordering: var lists are ordered, the for_each maps are not. Index through
  # the variable so subnet order is the caller's and stays stable across plans
  # (subnet_ids order is not semantically meaningful to EKS, but a churning
  # list shows up as a diff on every consumer that renders it).
  byo_provided_control_plane_ids = length(var.existing_control_plane_subnet_ids) > 0 ? var.existing_control_plane_subnet_ids : var.existing_workload_subnet_ids

  byo_provided_workload      = [for id in var.existing_workload_subnet_ids : data.aws_subnet.byo_provided_workload[id]]
  byo_provided_control_plane = [for id in local.byo_provided_control_plane_ids : data.aws_subnet.byo_provided_control_plane[id]]
  byo_provided_public        = [for id in var.existing_public_subnet_ids : data.aws_subnet.byo_provided_public[id]]

  byo_provided_all = concat(local.byo_provided_workload, local.byo_provided_control_plane, local.byo_provided_public)

  byo_provided_workload_azs      = distinct([for s in local.byo_provided_workload : s.availability_zone])
  byo_provided_control_plane_azs = distinct([for s in local.byo_provided_control_plane : s.availability_zone])

  byo_provided_foreign_vpc_subnets = [for s in local.byo_provided_all : s.id if s.vpc_id != var.existing_vpc_id]

  # An explicit load-balancer subnet list may name at most one subnet per AZ —
  # AWS rejects the whole set otherwise. private_subnet_ids is consumed as such
  # a list (internal load balancers pinned to the workload subnets, the ingress
  # gateway in BYO mode), so one workload subnet per AZ is what makes that
  # output usable at all. Karpenter and EKS want nothing more
  # than one subnet per AZ here either; a second subnet in an AZ would only buy
  # extra pod IP room, which is a capacity conversation with the network owner.
  byo_provided_workload_duplicate_azs = [
    for az in local.byo_provided_workload_azs : az
    if length([for s in local.byo_provided_workload : s.id if s.availability_zone == az]) > 1
  ]

  # Free-IP floors, not density targets. A workload subnet below this cannot
  # host a node plus its VPC CNI secondary IPs at all; a control-plane subnet
  # below it cannot hold the EKS-managed ENIs (AWS requires ≥6 free IPs and
  # recommends ≥16). Pod density in a centrally-managed network is a capacity
  # conversation with the network authority — see
  # min_free_ips_per_workload_subnet.
  byo_provided_workload_starved = [
    for s in local.byo_provided_workload : "${s.id} (${s.cidr_block}, ${s.available_ip_address_count} free)"
    if s.available_ip_address_count < var.min_free_ips_per_workload_subnet
  ]
  byo_provided_control_plane_starved = [
    for s in local.byo_provided_control_plane : "${s.id} (${s.cidr_block}, ${s.available_ip_address_count} free)"
    if s.available_ip_address_count < 6
  ]

  # A subnet whose governing route table has no 0.0.0.0/0 entry is isolated.
  # Ryvn cannot add the route in this mode, so it must fail before the cluster
  # is created rather than after nodes fail to bootstrap.
  byo_provided_unrouted_subnets = [
    for id in var.existing_workload_subnet_ids : id
    if !anytrue([for r in data.aws_route_table.byo_provided_workload[id].routes : r.cidr_block == "0.0.0.0/0"])
  ]
}

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
# Fail before any network resource is created, with an itemized reason. Every
# check here is cheap at plan time and expensive mid-apply: an AWS conflict
# halfway through leaves a partial network behind.

resource "terraform_data" "byo_vpc_validation" {
  count = local.byo_carve_enabled ? 1 : 0

  input = {
    vpc_id      = var.existing_vpc_id
    egress_mode = var.egress_mode
  }

  lifecycle {
    precondition {
      condition     = !var.enable_transit_gateway_subnets
      error_message = "enable_transit_gateway_subnets cannot be used with existing_vpc_id. Ryvn's TGW landing-pad subnets are a Ryvn-provisioned-VPC feature; in a BYO VPC the attachment subnets already exist and Ryvn carves around them."
    }

    precondition {
      condition     = var.egress_mode != "transit_gateway" || can(regex("^tgw-", coalesce(var.egress_target_id, "")))
      error_message = "egress_mode = \"transit_gateway\" requires egress_target_id to be a transit gateway ID (tgw-...)."
    }

    precondition {
      condition     = var.egress_mode != "nat_gateway" || can(regex("^nat-", coalesce(var.egress_target_id, "")))
      error_message = "egress_mode = \"nat_gateway\" requires egress_target_id to be a NAT gateway ID (nat-...)."
    }

    precondition {
      condition     = var.egress_mode != "create_nat" || var.egress_target_id == null
      error_message = "egress_target_id is not used when egress_mode = \"create_nat\" — Ryvn creates the NAT gateway itself. Remove egress_target_id, or set egress_mode to transit_gateway/nat_gateway to route to it."
    }

    precondition {
      condition     = tonumber(split("/", local.byo_vpc_cidr)[1]) <= 20
      error_message = "The existing VPC's primary CIDR must be /20 or larger. The carve is proportional to the VPC prefix — control-plane and public subnets are VPC+8 bits, which falls below AWS's /28 subnet minimum beyond /20. Note that a /20 yields /24 workload subnets (~251 usable IPs per AZ), which caps pod density under VPC CNI's IP-per-pod model; /16 is the recommended allocation."
    }

    precondition {
      condition     = length(local.byo_workload_cidrs) >= 2
      error_message = "At least 2 workload subnets in distinct availability zones are required for EKS."
    }

    precondition {
      condition     = length(local.byo_control_plane_cidrs) >= 2
      error_message = "At least 2 control-plane subnets in distinct availability zones are required — EKS rejects a cluster whose control-plane ENIs span fewer than 2 AZs."
    }

    precondition {
      condition = alltrue([
        length(local.byo_workload_cidrs) <= length(local.azs),
        length(local.byo_control_plane_cidrs) <= length(local.azs),
        length(local.byo_public_cidrs) <= length(local.azs),
      ])
      error_message = "byo_workload_subnet_cidrs, byo_control_plane_subnet_cidrs and byo_public_subnet_cidrs each take at most ${length(local.azs)} entries — one per availability zone (${join(", ", local.azs)}). AZ assignment is positional over that list."
    }

    precondition {
      condition     = length(local.byo_out_of_vpc_cidrs) == 0
      error_message = "These planned subnet CIDRs fall outside every CIDR association of ${var.existing_vpc_id}: ${join(", ", local.byo_out_of_vpc_cidrs)}. The VPC's associations are: ${join(", ", local.vpc_cidrs)}. Subnets can only be carved from ranges the VPC actually has."
    }

    precondition {
      condition     = length(local.byo_overlapping_cidrs) == 0
      error_message = "The planned subnet carve overlaps subnets that already exist in the VPC: ${join(", ", local.byo_overlapping_cidrs)}. Pass explicit free blocks via byo_workload_subnet_cidrs / byo_control_plane_subnet_cidrs / byo_public_subnet_cidrs, or remove the conflicting subnets. Note that TGW attachment subnets must be kept — deleting them tears down the attachment."
    }

    precondition {
      condition     = length(local.byo_self_overlapping_cidrs) == 0
      error_message = "The planned subnet carve overlaps itself: ${join(", ", local.byo_self_overlapping_cidrs)}. Subnet roles are not independently placeable — moving the workload subnets off the head of the range usually requires moving the control-plane subnets too. Supply a coherent set across byo_workload_subnet_cidrs, byo_control_plane_subnet_cidrs and byo_public_subnet_cidrs."
    }

    precondition {
      condition     = length(local.byo_uncovered_azs) == 0
      error_message = "The transit gateway attachment does not have an ENI in every availability zone the carve targets: ${join(", ", local.byo_uncovered_azs)}. Egress from an uncovered AZ is silently blackholed. Extend the attachment to cover these AZs, or restrict the carve to the attached AZs."
    }
  }
}

# ----------------------------------------------------------------------------
# Preconditions — BYO subnets mode
# ----------------------------------------------------------------------------
# Nothing here can be repaired by Ryvn: in this mode every fix is a request to
# the network authority, so each message names the required end state rather
# than an action Ryvn could take.

resource "terraform_data" "byo_subnets_validation" {
  count = local.byo_subnets_enabled ? 1 : 0

  input = {
    vpc_id                   = var.existing_vpc_id
    egress_mode              = var.egress_mode
    workload_subnet_ids      = var.existing_workload_subnet_ids
    control_plane_subnet_ids = local.byo_provided_control_plane_ids
    public_subnet_ids        = var.existing_public_subnet_ids
  }

  lifecycle {
    precondition {
      condition     = !var.enable_transit_gateway_subnets
      error_message = "enable_transit_gateway_subnets cannot be used with existing_workload_subnet_ids. Ryvn's TGW landing-pad subnets are a Ryvn-provisioned-VPC feature, and BYO subnets mode creates no subnets at all."
    }

    precondition {
      condition     = length(var.byo_workload_subnet_cidrs) == 0 && length(var.byo_control_plane_subnet_cidrs) == 0 && length(var.byo_public_subnet_cidrs) == 0
      error_message = "byo_*_subnet_cidrs configure the carve, which is not used when existing_workload_subnet_ids is set — the two are alternative ways to obtain subnets. Remove the CIDR lists to consume the provided subnets, or remove existing_workload_subnet_ids to carve."
    }

    precondition {
      condition     = var.egress_mode != "create_nat"
      error_message = "egress_mode = \"create_nat\" cannot be used with existing_workload_subnet_ids: creating a NAT gateway requires a public subnet and a default route Ryvn does not create in this mode. Set egress_mode to transit_gateway (centralized egress) or nat_gateway, and make sure the provided subnets already route 0.0.0.0/0 to it."
    }

    # egress_target_id is optional here, unlike carve mode: the route to the
    # the egress path already exists and Ryvn needs the target only to report
    # egress IPs or to validate AZ coverage of a TGW attachment. When it is
    # given it must still be the right kind of thing.
    precondition {
      condition     = var.egress_mode != "transit_gateway" || var.egress_target_id == null || can(regex("^tgw-", var.egress_target_id))
      error_message = "egress_target_id must be a transit gateway ID (tgw-...) when egress_mode = \"transit_gateway\". Leave it unset if the transit gateway is not visible from this account — the provided subnets' existing routes are what carry egress."
    }

    precondition {
      condition     = var.egress_mode != "nat_gateway" || var.egress_target_id == null || can(regex("^nat-", var.egress_target_id))
      error_message = "egress_target_id must be a NAT gateway ID (nat-...) when egress_mode = \"nat_gateway\". Leave it unset if the NAT is not in this VPC — the provided subnets' existing routes are what carry egress, and Ryvn will report the environment's outbound IPs as unknown."
    }

    precondition {
      condition     = length(local.byo_provided_foreign_vpc_subnets) == 0
      error_message = "These provided subnets are not in ${var.existing_vpc_id}: ${join(", ", local.byo_provided_foreign_vpc_subnets)}. EKS requires every cluster subnet to belong to one VPC."
    }

    precondition {
      condition     = length(local.byo_provided_workload_azs) >= 2
      error_message = "existing_workload_subnet_ids must span at least 2 availability zones; the provided subnets cover ${length(local.byo_provided_workload_azs) == 0 ? "none" : join(", ", local.byo_provided_workload_azs)}. Ask the network owner for a subnet in a second AZ."
    }

    precondition {
      condition     = length(local.byo_provided_workload_duplicate_azs) == 0
      error_message = "existing_workload_subnet_ids must have exactly one subnet per availability zone; more than one was provided in ${join(", ", local.byo_provided_workload_duplicate_azs)}. Pinning a load balancer to an explicit subnet list requires one subnet per AZ (an AWS NLB constraint), and Karpenter/EKS need no more than that here — supply one workload subnet per AZ."
    }

    precondition {
      condition     = length(local.byo_provided_control_plane_azs) >= 2
      error_message = "The control-plane subnets must span at least 2 availability zones — EKS rejects a cluster whose control-plane ENIs span fewer than 2 AZs. Provided: ${length(local.byo_provided_control_plane_azs) == 0 ? "none" : join(", ", local.byo_provided_control_plane_azs)}."
    }

    precondition {
      condition     = length(local.byo_provided_control_plane_starved) == 0
      error_message = "These control-plane subnets have too few free IP addresses for the EKS-managed ENIs (AWS requires at least 6 free, and recommends 16): ${join(", ", local.byo_provided_control_plane_starved)}."
    }

    precondition {
      condition     = length(local.byo_provided_workload_starved) == 0
      error_message = "These workload subnets have fewer than ${var.min_free_ips_per_workload_subnet} free IP addresses: ${join(", ", local.byo_provided_workload_starved)}. Under the VPC CNI every pod consumes a subnet IP, so this caps how much can run in the AZ. Ask the network owner for larger subnets, or lower min_free_ips_per_workload_subnet if the environment is deliberately small."
    }

    precondition {
      condition     = length(local.byo_provided_unrouted_subnets) == 0
      error_message = "These workload subnets have no 0.0.0.0/0 route in their governing route table: ${join(", ", local.byo_provided_unrouted_subnets)}. Ryvn creates no routes in this mode, and nodes must reach ECR, the EKS API and the Ryvn control plane to join. Ask the network owner to route the subnets to their transit gateway, NAT or firewall."
    }

    precondition {
      condition     = length(local.byo_uncovered_azs) == 0
      error_message = "The transit gateway attachment does not have an ENI in every availability zone the provided workload subnets use: ${join(", ", local.byo_uncovered_azs)}. Egress from an uncovered AZ is silently blackholed. Extend the attachment to cover these AZs, or provide workload subnets only in the attached AZs."
    }
  }
}

# BYO settings without existing_vpc_id must be an error, not a silent fallback
# to a freshly created VPC. Environment config reaches this module unfiltered,
# so a dropped or mistyped existing_vpc_id would otherwise provision a brand-new
# NAT'd VPC while the caller believes they configured BYO egress.
resource "terraform_data" "byo_vars_require_vpc" {
  count = local.byo_enabled ? 0 : 1

  lifecycle {
    precondition {
      condition = alltrue([
        var.egress_mode == "create_nat",
        var.egress_target_id == null,
        length(var.byo_workload_subnet_cidrs) == 0,
        length(var.byo_control_plane_subnet_cidrs) == 0,
        length(var.byo_public_subnet_cidrs) == 0,
        length(var.existing_workload_subnet_ids) == 0,
        length(var.existing_control_plane_subnet_ids) == 0,
        length(var.existing_public_subnet_ids) == 0,
      ])
      error_message = "egress_mode, egress_target_id, byo_*_subnet_cidrs and existing_*_subnet_ids only apply to BYO VPC mode, but existing_vpc_id is not set. Set existing_vpc_id to provision into an existing VPC, or remove the BYO settings."
    }
  }
}

# Control-plane and public subnet lists are meaningless without the workload
# list: subnets mode is switched on by existing_workload_subnet_ids, so a
# config that supplies only the other two would silently carve instead.
resource "terraform_data" "byo_subnet_lists_require_workload" {
  count = local.byo_subnets_enabled ? 0 : 1

  lifecycle {
    precondition {
      condition     = length(var.existing_control_plane_subnet_ids) == 0 && length(var.existing_public_subnet_ids) == 0
      error_message = "existing_control_plane_subnet_ids and existing_public_subnet_ids require existing_workload_subnet_ids — that list is what selects BYO subnets mode. Without it Ryvn would carve new subnets and ignore the ones you passed."
    }
  }
}

# ----------------------------------------------------------------------------
# Carved subnets
# ----------------------------------------------------------------------------
# element() instead of local.azs[count.index]: an oversized CIDR list must be
# reported by the length precondition above, not by an index error that would
# preempt it during plan evaluation.
#
# Every count here and in the route table / route / association / NAT resources
# below reduces to 0 in subnets mode: the CIDR locals are gated on
# byo_carve_enabled, and the associations count the carved subnets. That is the
# no-topology-mutation guarantee — it holds by construction, without a second
# mode conditional per resource that could drift from the first.

resource "aws_subnet" "byo_workload" {
  count             = length(local.byo_workload_cidrs)
  vpc_id            = var.existing_vpc_id
  cidr_block        = local.byo_workload_cidrs[count.index]
  availability_zone = element(local.azs, count.index)

  tags = merge(local.tags, {
    Name                                          = "ryvn-${var.environment_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "karpenter.sh/discovery"                      = local.cluster_name
  })

  depends_on = [terraform_data.byo_vpc_validation]
}

# Control-plane ENIs. Deliberately given a route table with no default route,
# mirroring the intra subnets on the Ryvn-provisioned path — this traffic must
# not traverse the existing inspection path.
resource "aws_subnet" "byo_control_plane" {
  count             = length(local.byo_control_plane_cidrs)
  vpc_id            = var.existing_vpc_id
  cidr_block        = local.byo_control_plane_cidrs[count.index]
  availability_zone = element(local.azs, count.index)

  tags = merge(local.tags, {
    Name = "ryvn-${var.environment_name}-intra-${count.index + 1}"
  })

  depends_on = [terraform_data.byo_vpc_validation]
}

resource "aws_subnet" "byo_public" {
  count                   = length(local.byo_public_cidrs)
  vpc_id                  = var.existing_vpc_id
  cidr_block              = local.byo_public_cidrs[count.index]
  availability_zone       = element(local.azs, count.index)
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name                                          = "ryvn-${var.environment_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  })

  depends_on = [terraform_data.byo_vpc_validation]
}

# ----------------------------------------------------------------------------
# Route tables — Ryvn owns the route tables for the subnets Ryvn creates
# ----------------------------------------------------------------------------

resource "aws_route_table" "byo_workload" {
  count  = local.byo_carve_enabled ? 1 : 0
  vpc_id = var.existing_vpc_id

  tags = merge(local.tags, {
    Name = "ryvn-${var.environment_name}-private-rt"
  })
}

resource "aws_route" "byo_workload_default" {
  count                  = local.byo_carve_enabled ? 1 : 0
  route_table_id         = aws_route_table.byo_workload[0].id
  destination_cidr_block = "0.0.0.0/0"

  # Exactly one of these is non-null per egress_mode. Everything beyond the
  # attachment — TGW route tables, inspection, return path — is external.
  transit_gateway_id = var.egress_mode == "transit_gateway" ? var.egress_target_id : null
  nat_gateway_id     = var.egress_mode == "nat_gateway" ? var.egress_target_id : one(aws_nat_gateway.byo[*].id)
}

resource "aws_route_table_association" "byo_workload" {
  count          = length(aws_subnet.byo_workload)
  subnet_id      = aws_subnet.byo_workload[count.index].id
  route_table_id = aws_route_table.byo_workload[0].id
}

resource "aws_route_table" "byo_control_plane" {
  count  = local.byo_carve_enabled ? 1 : 0
  vpc_id = var.existing_vpc_id

  tags = merge(local.tags, {
    Name = "ryvn-${var.environment_name}-intra-rt"
  })
}

resource "aws_route_table_association" "byo_control_plane" {
  count          = length(aws_subnet.byo_control_plane)
  subnet_id      = aws_subnet.byo_control_plane[count.index].id
  route_table_id = aws_route_table.byo_control_plane[0].id
}

resource "aws_route_table" "byo_public" {
  count  = local.byo_public_enabled ? 1 : 0
  vpc_id = var.existing_vpc_id

  tags = merge(local.tags, {
    Name = "ryvn-${var.environment_name}-public-rt"
  })
}

resource "aws_route" "byo_public_default" {
  count                  = local.byo_public_enabled ? 1 : 0
  route_table_id         = aws_route_table.byo_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = data.aws_internet_gateway.existing[0].id
}

resource "aws_route_table_association" "byo_public" {
  count          = length(aws_subnet.byo_public)
  subnet_id      = aws_subnet.byo_public[count.index].id
  route_table_id = aws_route_table.byo_public[0].id
}

# ----------------------------------------------------------------------------
# NAT (create_nat mode only)
# ----------------------------------------------------------------------------

resource "aws_eip" "byo_nat" {
  count  = local.byo_public_enabled ? 1 : 0
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "ryvn-${var.environment_name}-nat-eip"
  })
}

resource "aws_nat_gateway" "byo" {
  count         = local.byo_public_enabled ? 1 : 0
  allocation_id = aws_eip.byo_nat[0].id
  subnet_id     = aws_subnet.byo_public[0].id

  tags = merge(local.tags, {
    Name = "ryvn-${var.environment_name}-nat"
  })

  depends_on = [aws_route.byo_public_default]
}

# ----------------------------------------------------------------------------
# Normalized network contract
# ----------------------------------------------------------------------------
# The single seam between "Ryvn made the VPC" and "it already existed". Every
# other file in this module reads these locals and never branches on ownership.

locals {
  vpc_id   = local.byo_enabled ? var.existing_vpc_id : one(module.vpc[*].vpc_id)
  vpc_name = local.byo_enabled ? try(one(data.aws_vpc.existing[*].tags)["Name"], var.existing_vpc_id) : one(module.vpc[*].name)

  vpc_cidr_primary = local.byo_enabled ? local.byo_vpc_cidr : one(module.vpc[*].vpc_cidr_block)

  # All CIDR associations, not just the primary. BYO VPCs commonly carry
  # secondary associations from IP exhaustion; consumers that build SG rules or
  # proxy trust lists from "the VPC CIDR" need the full set.
  vpc_cidrs = local.byo_enabled ? [
    for a in flatten(data.aws_vpc.existing[*].cidr_block_associations) : a.cidr_block
    ] : concat(
    compact([one(module.vpc[*].vpc_cidr_block)]),
    flatten(module.vpc[*].vpc_secondary_cidr_blocks)
  )

  # Three-way, in mode order: provided subnets, carved subnets, Ryvn's VPC. The
  # subnets-mode branch reads the data sources rather than the raw variables so
  # CIDRs and IDs come from one resolved view of the same subnet.
  private_subnet_ids = local.byo_subnets_enabled ? [for s in local.byo_provided_workload : s.id] : (
    local.byo_enabled ? aws_subnet.byo_workload[*].id : flatten(module.vpc[*].private_subnets)
  )
  private_subnet_cidr_blocks = local.byo_subnets_enabled ? [for s in local.byo_provided_workload : s.cidr_block] : (
    local.byo_enabled ? aws_subnet.byo_workload[*].cidr_block : flatten(module.vpc[*].private_subnets_cidr_blocks)
  )

  public_subnet_ids = local.byo_subnets_enabled ? [for s in local.byo_provided_public : s.id] : (
    local.byo_enabled ? aws_subnet.byo_public[*].id : flatten(module.vpc[*].public_subnets)
  )
  public_subnet_cidr_blocks = local.byo_subnets_enabled ? [for s in local.byo_provided_public : s.cidr_block] : (
    local.byo_enabled ? aws_subnet.byo_public[*].cidr_block : flatten(module.vpc[*].public_subnets_cidr_blocks)
  )

  control_plane_subnet_ids = local.byo_subnets_enabled ? [for s in local.byo_provided_control_plane : s.id] : (
    local.byo_enabled ? aws_subnet.byo_control_plane[*].id : flatten(module.vpc[*].intra_subnets)
  )

  default_security_group_id = local.byo_enabled ? one(data.aws_security_group.existing_default[*].id) : one(module.vpc[*].default_security_group_id)

  # The AZs the environment actually occupies. In subnets mode that is whatever
  # the provided subnets cover, which may be a subset of the region's AZs (a
  # centrally-managed VPC commonly spans two) — reporting local.azs there would
  # claim capacity in an AZ the cluster has no subnet in.
  network_azs = local.byo_subnets_enabled ? sort(distinct(concat(
    local.byo_provided_workload_azs,
    local.byo_provided_control_plane_azs,
    [for s in local.byo_provided_public : s.availability_zone],
  ))) : local.azs

  # Under transit_gateway egress there is no in-VPC NAT: the egress IPs are
  # whatever the centralized egress path presents. Report that as unknown
  # rather than as an empty list that reads like an answer.
  # In subnets mode with nat_gateway egress the caller may not have named a NAT
  # (the route already exists and Ryvn does not need a target), so the IPs are
  # unknown there too.
  outbound_ips = local.byo_enabled ? (
    var.egress_mode == "nat_gateway" ? compact(data.aws_nat_gateway.existing[*].public_ip) : aws_nat_gateway.byo[*].public_ip
  ) : flatten(module.vpc[*].nat_public_ips)

  outbound_ips_known = !local.byo_enabled || (var.egress_mode == "create_nat" || (var.egress_mode == "nat_gateway" && var.egress_target_id != null))
}

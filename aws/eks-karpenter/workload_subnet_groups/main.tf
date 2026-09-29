# Network-owned, named workload subnet groups: an append-only allocation ledger
# carved from the region of the VPC left free by the cluster layout.
#
# Allocation: cidrsubnets(vpc_cidr, thirteen fixed new_bits=4 reservations,
# then one entry per group/AZ in declaration order). Blocks 0..12 belong to the
# cluster layout (existing plus workload_subnets_per_az growth); block 15 is
# reserved (transit gateway / future). Only blocks 13..14 are available. Retired
# entries still consume their span; they are filtered out only when subnets
# and inventory are created.
#
# Geometry guard: one terraform_data record per group (retired included) stores
# {position, ipv4_prefix_length, availability_zones, cidrs_by_az} on first
# apply and never rewrites it. A postcondition compares that record with the
# freshly calculated geometry, so resizing, renaming, reordering groups or
# their AZs fails the plan before any subnet changes. Subnets consume the
# record's CIDRs, not the raw calculation. prevent_destroy on the records
# rejects removing, renaming or clearing entries (retired ones included) and
# blocks a plain destroy; a full teardown forgets only these records from
# state first (README). The guard cannot recover history that was deleted from
# configuration or state; keep retired entries as tombstones.
terraform {
  required_version = ">= 1.5.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.28.0, != 6.57.0, < 7.0.0" }
  }
}

locals {
  vpc_prefix_length = tonumber(split("/", var.vpc_cidr)[1])
  min_prefix_length = max(16, local.vpc_prefix_length + 4)
  max_prefix_length = 28

  # Flattened group/AZ requests in declaration order, retired included.
  entries = flatten([for position, group in var.groups : [
    for az in group.availability_zones : {
      position = position
      name     = group.name
      az       = az
      new_bits = group.ipv4_prefix_length - local.vpc_prefix_length
    }
  ]])

  prefix_lengths_valid = alltrue([for group in var.groups :
    floor(group.ipv4_prefix_length) == group.ipv4_prefix_length &&
    group.ipv4_prefix_length >= local.min_prefix_length &&
    group.ipv4_prefix_length <= local.max_prefix_length
  ])

  # cidrsubnets fails when the requests do not fit the VPC; keep that a
  # contract failure with a readable message instead of a function error.
  allocation_fits = local.prefix_lengths_valid && can(cidrsubnets(var.vpc_cidr, concat([for _ in range(13) : 4], local.entries[*].new_bits)...))
  allocation      = local.allocation_fits && length(local.entries) > 0 ? slice(cidrsubnets(var.vpc_cidr, concat([for _ in range(13) : 4], local.entries[*].new_bits)...), 13, 13 + length(local.entries)) : []

  # [first, last] address of each allocation as integers.
  allocation_ranges = [for cidr in local.allocation : [
    sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)]),
    sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  ]]
  reserved_block_start = sum([for i, octet in split(".", cidrhost(cidrsubnet(var.vpc_cidr, 4, 15), 0)) : tonumber(octet) * pow(256, 3 - i)])
  spilled_cidrs        = [for index, cidr in local.allocation : cidr if local.allocation_ranges[index][1] >= local.reserved_block_start]

  reserved_ranges = [for cidr in var.reserved_cidrs : [
    sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)]),
    sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  ]]
  overlapping_cidrs = [for index, cidr in local.allocation : cidr
    if anytrue([for range in local.reserved_ranges : local.allocation_ranges[index][0] <= range[1] && range[0] <= local.allocation_ranges[index][1]])
  ]

  geometry = { for position, group in var.groups : group.name => {
    position           = position
    ipv4_prefix_length = group.ipv4_prefix_length
    availability_zones = group.availability_zones
    cidrs_by_az        = { for index, entry in local.entries : entry.az => try(local.allocation[index], null) if entry.name == group.name }
  } }

  active_groups = { for group in var.groups : group.name => group if !group.retired }
  active_placements = merge([for group in values(local.active_groups) : {
    for az in group.availability_zones : "${group.name}/${az}" => { name = group.name, az = az }
  }]...)
}

resource "terraform_data" "contract" {
  input = length(var.groups)
  lifecycle {
    precondition {
      condition     = local.prefix_lengths_valid
      error_message = "additional_subnet_groups ipv4_prefix_length must be a whole number from ${local.min_prefix_length} to ${local.max_prefix_length} for VPC ${var.vpc_cidr}."
    }
    precondition {
      condition     = alltrue(flatten([for group in var.groups : [for az in group.availability_zones : contains(var.azs, az)]]))
      error_message = "additional_subnet_groups availability_zones must be chosen from the environment's zones ${join(", ", var.azs)}."
    }
    precondition {
      condition     = local.allocation_fits
      error_message = "additional_subnet_groups do not fit ${var.vpc_cidr}: the allocation region is VPC blocks 13-14 (${cidrsubnet(var.vpc_cidr, 4, 13)} and ${cidrsubnet(var.vpc_cidr, 4, 14)}) and aligned requests are placed in declaration order. Append a smaller group or choose a larger VPC when creating the environment; existing allocations are never moved."
    }
    precondition {
      condition     = length(local.spilled_cidrs) == 0
      error_message = "additional_subnet_groups ${join(", ", local.spilled_cidrs)} reach reserved VPC block 15 (${cidrsubnet(var.vpc_cidr, 4, 15)}). Only blocks 13-14 are available; append a smaller group or choose a larger VPC."
    }
    precondition {
      condition     = length(local.overlapping_cidrs) == 0
      error_message = "additional_subnet_groups ${join(", ", local.overlapping_cidrs)} overlap existing or reserved subnets ${join(", ", var.reserved_cidrs)}."
    }
  }
}

resource "terraform_data" "geometry" {
  for_each = local.geometry

  input = each.value

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [input]
    postcondition {
      condition     = jsonencode(self.output) == jsonencode(local.geometry[each.key])
      error_message = "additional_subnet_groups[${each.key}] recorded allocation ${jsonencode(self.output)} differs from the calculated ${jsonencode(local.geometry[each.key])}. Allocations are append-only: keep this group's position, ipv4_prefix_length and availability_zones as first applied (retired groups stay in the list as tombstones); to resize or move it, append a new group and migrate its consumers."
    }
  }

  depends_on = [terraform_data.contract]
}

resource "aws_subnet" "group" {
  for_each                = local.active_placements
  vpc_id                  = var.vpc_id
  availability_zone       = each.value.az
  cidr_block              = terraform_data.geometry[each.value.name].output.cidrs_by_az[each.value.az]
  map_public_ip_on_launch = false
  # Deliberately no kubernetes.io/cluster, karpenter.sh/discovery or role/cni
  # tags: these subnets are outside cluster, Karpenter, Cilium and LB discovery.
  tags = merge(var.tags, {
    Name                            = "${var.name}-${replace(each.key, "/", "-")}"
    "ryvn.ai/workload-subnet-group" = each.value.name
  })
}

# Dedicated per-subnet route table with only the VPC-local route. Attaching the
# group to the egress firewall adds an inspected default route to this table;
# detaching removes it again. Nothing here ever points at a NAT gateway.
resource "aws_route_table" "group" {
  for_each = local.active_placements
  vpc_id   = var.vpc_id
  tags     = merge(var.tags, { Name = "${var.name}-${replace(each.key, "/", "-")}" })
}

resource "aws_route_table_association" "group" {
  for_each       = local.active_placements
  subnet_id      = aws_subnet.group[each.key].id
  route_table_id = aws_route_table.group[each.key].id
}

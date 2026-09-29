terraform {
  required_version = ">= 1.5.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.28.0, != 6.57.0, < 7.0.0" }
  }
}

locals {
  public_suffixes = toset([for line in split("\n", file("${path.module}/public_suffix_list.dat")) : trimspace(line) if trimspace(line) != "" && !startswith(line, "//")])
  # Attached subnet placements (attachment-key/AZ), resolved from the
  # network-owned groups. Unknown group keys resolve to nothing here and are
  # rejected by the contract below.
  worker_subnets = merge([for key, attachment in var.attachments : {
    for az, placement in lookup(var.subnet_groups, attachment.subnet_group_key, { subnets_by_az = {} }).subnets_by_az : "${key}/${az}" => {
      attachment_key = key
      policy_key     = attachment.policy_key
      az             = az
      subnet_id      = placement.subnet_id
      cidr           = placement.ipv4_cidr
      route_table_id = placement.route_table_id
    }
  }]...)
  cluster_sources_by_az = { for az in var.azs : az => concat([var.cluster_subnets_by_az[az].ipv4_cidr], lookup(var.cluster_source_cidrs_by_az, az, [])) }
  class_sources = merge({ cluster = flatten(values(local.cluster_sources_by_az)) }, {
    for key in keys(var.attachments) : key => [for p in values(local.worker_subnets) : p.cidr if p.attachment_key == key]
  })
  class_policies = merge({ cluster = var.cluster_policy_key }, { for key, attachment in var.attachments : key => attachment.policy_key })
  source_cidrs   = flatten(values(local.class_sources))
  home_net       = distinct(local.source_cidrs)
  # Raw (not deduplicated) so an exact duplicate source CIDR fails the disjointness check.
  all_subnets = concat(local.source_cidrs, values(var.firewall_subnet_cidrs), values(var.nat_subnet_cidrs), var.reserved_subnet_cidrs)
  subnet_ranges = [for cidr in local.all_subnets : [
    sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)]),
    sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  ]]
  vpc_cidrs = distinct(concat([var.vpc_cidr], var.vpc_cidrs))
  vpc_ranges = [for cidr in local.vpc_cidrs : [
    sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)]),
    sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  ]]
  excluded_destination_cidrs = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4"]
  excluded_destination_ranges = [for cidr in local.excluded_destination_cidrs : [
    sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)]),
    sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  ]]
  exception_destination_ranges = [for policy in values(var.policies) : [for rule in values(policy.network_allow) : [for cidr in rule.destination_ipv4_cidrs : [
    sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)]),
    sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  ]]]]
  # AWS counts variable values toward the per-rule limit, including both
  # HOME_NET references in the reserved protocol-drop rule.
  expanded_rule_lines = [for line in split("\n", local.suricata_rules) :
    replace(line, "$HOME_NET", "[${join(",", local.home_net)}]")
  ]
}

resource "terraform_data" "contract" {
  input = var.cluster_policy_key
  lifecycle {
    precondition {
      condition     = contains(keys(var.policies), var.cluster_policy_key) && alltrue([for p in values(var.attachments) : contains(keys(var.policies), p.policy_key)]) && !contains(keys(var.attachments), "cluster")
      error_message = "Cluster and external attachment policy keys must exist; cluster is reserved."
    }
    precondition {
      condition     = alltrue([for p in values(var.attachments) : contains(keys(var.subnet_groups), p.subnet_group_key)]) && !contains(values(var.attachments)[*].subnet_group_key, "cluster") && !contains(keys(var.subnet_groups), "cluster")
      error_message = "Every attachment's subnet_group_key must name a known subnet group (${join(", ", keys(var.subnet_groups))}); the built-in cluster group cannot be attached as an external class."
    }
    precondition {
      condition     = length(distinct(values(var.attachments)[*].subnet_group_key)) == length(var.attachments)
      error_message = "A subnet group can be assigned to at most one attachment, even with the same policy; duplicates: ${join(", ", [for g in distinct(values(var.attachments)[*].subnet_group_key) : g if length([for p in values(var.attachments) : p if p.subnet_group_key == g]) > 1])}."
    }
    precondition {
      condition = alltrue([for domain in local.policy_domains :
        !startswith(domain, "*.") || !(
          contains(local.public_suffixes, trimprefix(domain, "*.")) ||
          (length(split(".", domain)) > 2 && contains(local.public_suffixes, "*.${join(".", slice(split(".", trimprefix(domain, "*.")), 1, length(split(".", trimprefix(domain, "*.")))))}") && !contains(local.public_suffixes, "!${trimprefix(domain, "*.")}"))
        )
      ])
      error_message = "A wildcard must have a registrable apex, not a public suffix."
    }
    precondition {
      condition = alltrue(flatten([for policy_ranges in local.exception_destination_ranges : [for rule_ranges in policy_ranges : [for range in rule_ranges :
        alltrue([for excluded in local.excluded_destination_ranges : range[1] < excluded[0] || excluded[1] < range[0]])
      ]]]))
      error_message = "Network exceptions cannot overlap private, provider-reserved or control-plane addresses."
    }
    precondition {
      condition     = toset(keys(var.cluster_subnets_by_az)) == toset(var.azs) && toset(keys(var.firewall_subnet_cidrs)) == toset(var.azs) && toset(keys(var.nat_subnet_cidrs)) == toset(var.azs) && length(setsubtract(toset(keys(var.cluster_source_cidrs_by_az)), toset(var.azs))) == 0 && alltrue([for g in values(var.subnet_groups) : length(g.subnets_by_az) > 0 && length(setsubtract(toset(keys(g.subnets_by_az)), toset(var.azs))) == 0])
      error_message = "Every cluster, firewall and NAT zone must be covered; subnet group zones must be a nonempty subset."
    }
    precondition {
      condition = alltrue([for i, range in local.subnet_ranges :
        anytrue([for vpc in local.vpc_ranges : range[0] >= vpc[0] && range[1] <= vpc[1]]) &&
        alltrue([for j, other in local.subnet_ranges : range[1] < other[0] || other[1] < range[0] if i != j])
      ])
      error_message = "Protected source, NAT and firewall subnets must be disjoint and inside one of the declared VPC CIDRs."
    }
    precondition {
      condition     = length(distinct(local.generated_sids)) == length(local.generated_sids) && length(setintersection(toset(local.generated_sids), toset(local.reserved_sids))) == 0
      error_message = "Generated rule SIDs collide with each other or with a reserved SID; rename one of the colliding rule identities."
    }
    precondition {
      condition     = length(local.named_rules) + 1 <= local.rule_group_capacity
      error_message = "Generated rule count exceeds the managed rule group capacity (${local.rule_group_capacity})."
    }
    precondition {
      condition     = alltrue([for line in local.expanded_rule_lines : length(line) <= local.max_rule_bytes]) && length(local.suricata_rules) <= local.max_rules_bytes
      error_message = "A generated Suricata rule exceeds ${local.max_rule_bytes} bytes or the rule set exceeds ${local.max_rules_bytes} bytes."
    }
  }
}

resource "aws_networkfirewall_rule_group" "egress" {
  # Immutable after creation. One managed stateful group holding every rule;
  # AWS charges nothing per capacity unit and this is the per-group maximum,
  # which also consumes the firewall policy's default stateful budget.
  capacity = local.rule_group_capacity
  name     = "${var.name}-egress-rules"
  type     = "STATEFUL"
  tags     = var.tags

  rule_group {
    rule_variables {
      ip_sets {
        key = "HOME_NET"
        ip_set { definition = local.home_net }
      }
    }
    rules_source { rules_string = local.suricata_rules }
    stateful_rule_options { rule_order = "STRICT_ORDER" }
  }
  depends_on = [terraform_data.contract]
}

resource "aws_networkfirewall_firewall_policy" "egress" {
  name = "${var.name}-egress-policy"
  tags = var.tags
  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]
    stateful_engine_options {
      rule_order              = "STRICT_ORDER"
      stream_exception_policy = "DROP"
    }
    stateful_default_actions = ["aws:drop_established_app_layer_to_server", "aws:alert_established_app_layer_to_server"]
    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.egress.arn
      priority     = 1
    }
  }
}

resource "aws_subnet" "firewall" {
  for_each          = var.firewall_subnet_cidrs
  vpc_id            = var.vpc_id
  availability_zone = each.key
  cidr_block        = each.value
  tags              = merge(var.tags, { Name = "${var.name}-firewall-${each.key}" })
}

resource "aws_subnet" "nat" {
  for_each                = var.nat_subnet_cidrs
  vpc_id                  = var.vpc_id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })
}

resource "aws_eip" "nat" {
  for_each = var.nat_subnet_cidrs
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })
}

resource "aws_nat_gateway" "nat" {
  for_each      = var.nat_subnet_cidrs
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.nat[each.key].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })
  depends_on    = [aws_route.nat_default]
}

resource "aws_networkfirewall_firewall" "egress" {
  name                = "${var.name}-egress"
  vpc_id              = var.vpc_id
  firewall_policy_arn = aws_networkfirewall_firewall_policy.egress.arn
  tags                = var.tags

  delete_protection                 = var.change_protection
  subnet_change_protection          = var.change_protection
  firewall_policy_change_protection = var.change_protection
  dynamic "subnet_mapping" {
    for_each = aws_subnet.firewall
    content { subnet_id = subnet_mapping.value.id }
  }
}

locals {
  firewall_endpoints = { for az in var.azs : az => one(flatten([
    for state in aws_networkfirewall_firewall.egress.firewall_status[0].sync_states : [for attachment in state.attachment : attachment.endpoint_id if state.availability_zone == az]
  ])) }
}

resource "aws_route_table" "firewall" {
  for_each = var.firewall_subnet_cidrs
  vpc_id   = var.vpc_id
  tags     = merge(var.tags, { Name = "${var.name}-firewall-${each.key}" })
}
resource "aws_route_table" "nat" {
  for_each = var.nat_subnet_cidrs
  vpc_id   = var.vpc_id
  tags     = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })
  # Destroy NAT route tables before their firewall endpoints. This also handles
  # tables whose local route an operator previously redirected at an endpoint.
  depends_on = [aws_networkfirewall_firewall.egress]
}
resource "aws_route_table_association" "firewall" {
  for_each       = var.firewall_subnet_cidrs
  subnet_id      = aws_subnet.firewall[each.key].id
  route_table_id = aws_route_table.firewall[each.key].id
}
resource "aws_route_table_association" "nat" {
  for_each       = var.nat_subnet_cidrs
  subnet_id      = aws_subnet.nat[each.key].id
  route_table_id = aws_route_table.nat[each.key].id
}
resource "aws_route" "firewall_to_nat" {
  for_each               = var.nat_subnet_cidrs
  route_table_id         = aws_route_table.firewall[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat[each.key].id
}
resource "aws_route" "nat_default" {
  for_each               = var.nat_subnet_cidrs
  route_table_id         = aws_route_table.nat[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = var.igw_id
}
resource "terraform_data" "caller_cluster_default_routes" {
  input = var.cluster_default_route_ids
}
resource "aws_route" "cluster_default" {
  for_each               = var.cluster_default_route_ids == null ? var.cluster_subnets_by_az : {}
  route_table_id         = each.value.route_table_id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.firewall_endpoints[each.key]
  depends_on             = [aws_networkfirewall_logging_configuration.egress, aws_route.firewall_to_nat, aws_route.nat_return]
}
# Inspected default route on the attached group's own route table (which the
# network layer created with only the VPC-local route). Removing the
# attachment removes this route and nothing replaces it: the subnet keeps
# VPC-local reachability and no NAT path.
resource "aws_route" "worker_default" {
  for_each               = local.worker_subnets
  route_table_id         = each.value.route_table_id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.firewall_endpoints[each.value.az]
  depends_on             = [aws_networkfirewall_logging_configuration.egress, aws_route.firewall_to_nat, aws_route.nat_return]
}
locals {
  # distinct() so an exact duplicate source CIDR reaches the contract precondition instead of a for-expression key error.
  return_routes = { for item in flatten([for az in var.azs : [for cidr in distinct(concat(local.cluster_sources_by_az[az], [for p in values(local.worker_subnets) : p.cidr if p.az == az])) : { key = "${az}/${cidr}", az = az, cidr = cidr }]]) : item.key => item }
}
resource "aws_route" "nat_return" {
  for_each               = local.return_routes
  route_table_id         = aws_route_table.nat[each.value.az].id
  destination_cidr_block = each.value.cidr
  vpc_endpoint_id        = local.firewall_endpoints[each.value.az]
}

# AWS creates one nondeletable local route per VPC CIDR association in every
# NAT table the moment the table exists. The module leaves them alone; the
# per-source return routes above are the supported symmetric path. If one of
# those is deleted out of band, return traffic falls back to the local route
# uninspected, so these identifiers exist for audit and drift checks.
locals {
  nat_local_routes = { for item in flatten([for az in var.azs : [for cidr in local.vpc_cidrs : { az = az, cidr = cidr }]]) : "${item.az}/${item.cidr}" => {
    availability_zone      = item.az
    route_table_id         = aws_route_table.nat[item.az].id
    destination_cidr_block = item.cidr
    firewall_endpoint_id   = local.firewall_endpoints[item.az]
  } }
}

resource "aws_cloudwatch_log_group" "alert" {
  name              = "/aws/network-firewall/${var.name}/alert"
  retention_in_days = 30
  tags              = var.tags
}
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/aws/network-firewall/${var.name}/flow"
  retention_in_days = 30
  tags              = var.tags
}
resource "aws_networkfirewall_logging_configuration" "egress" {
  firewall_arn = aws_networkfirewall_firewall.egress.arn
  logging_configuration {
    log_destination_config {
      log_destination      = { logGroup = aws_cloudwatch_log_group.alert.name }
      log_destination_type = "CloudWatchLogs"
      log_type             = "ALERT"
    }
    log_destination_config {
      log_destination      = { logGroup = aws_cloudwatch_log_group.flow.name }
      log_destination_type = "CloudWatchLogs"
      log_type             = "FLOW"
    }
  }
}

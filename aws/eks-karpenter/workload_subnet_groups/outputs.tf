output "geometry" {
  description = "Calculated allocation per group (retired included): position, prefix length, ordered zones and cidrs_by_az. Plan-known; the geometry guard's postcondition fails the plan whenever this differs from a group's recorded terraform_data record."
  value       = local.geometry
}

output "groups" {
  description = "Active groups keyed by name with native per-AZ subnet, CIDR and dedicated route table. Network inventory only: it says nothing about firewall attachment or inspection readiness. Keys and CIDRs are plan-known so callers can key routes by them."
  value = { for name, group in local.active_groups : name => {
    ipv4_prefix_length = group.ipv4_prefix_length
    availability_zones = group.availability_zones
    subnets_by_az = { for az in group.availability_zones : az => {
      subnet_id      = aws_subnet.group["${name}/${az}"].id
      ipv4_cidr      = local.geometry[name].cidrs_by_az[az]
      route_table_id = aws_route_table.group["${name}/${az}"].id
    } }
  } }
}

output "active_cidrs" {
  description = "CIDRs of every active (non-retired) group subnet, in allocation order."
  value       = [for index, entry in local.entries : try(local.allocation[index], null) if contains(keys(local.active_groups), entry.name)]
}

output "subnet_ids" {
  description = "Active subnet IDs keyed group-name/AZ."
  value       = { for key, subnet in aws_subnet.group : key => subnet.id }
}

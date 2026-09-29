output "suricata_rules" {
  value = local.suricata_rules
}

output "effective_rules" {
  description = "Every generated pass rule keyed by its stable identity (class/kind/name), from the same compiler data as suricata_rules: SID, source class and policy key, origin (platform takes precedence), platform_required and customer_configured provenance flags, protocol, ports, domain or destination CIDRs, reason, and whether a TCP 80/443 IP exception bypasses Host/SNI matching. Removing a customer entry does not revoke a platform-required allowance. The leading protocol drop rule (sid 100000001) is not listed."
  value       = local.effective_rules
}

output "cluster_subnet_ids" {
  value      = [for az in var.azs : var.cluster_subnets_by_az[az].subnet_id]
  depends_on = [aws_route.cluster_default, terraform_data.caller_cluster_default_routes, aws_route_table_association.firewall, aws_route_table_association.nat, aws_networkfirewall_logging_configuration.egress]
}

output "attachments" {
  description = "Version 1 attachment descriptors keyed by attachment: the selected group's native subnet, CIDR and route table per AZ, published only once the inspected forward and return routes and logging exist."
  value = { for key, attachment in var.attachments : key => {
    schema_version   = 1
    provider         = "aws"
    policy_key       = attachment.policy_key
    subnet_group_key = attachment.subnet_group_key
    vpc_id           = var.vpc_id
    subnets_by_az = { for az, placement in lookup(var.subnet_groups, attachment.subnet_group_key, { subnets_by_az = {} }).subnets_by_az : az => {
      subnet_id      = placement.subnet_id
      ipv4_cidr      = placement.ipv4_cidr
      route_table_id = placement.route_table_id
    } }
  } }
  depends_on = [aws_route.worker_default, aws_route_table_association.firewall, aws_route_table_association.nat, aws_route.firewall_to_nat, aws_route.nat_return, aws_networkfirewall_logging_configuration.egress]
}

output "nat_public_ips" {
  value = [for az in var.azs : aws_eip.nat[az].public_ip]
}

output "nat_route_table_ids" {
  description = "Per-AZ dedicated NAT route tables (audit and drift-check identifiers). Their VPC-local routes are AWS-created and stay unmanaged."
  value       = { for az in var.azs : az => aws_route_table.nat[az].id }
}

output "nat_local_routes" {
  description = "Audit identifiers, one per AZ NAT table and VPC CIDR association (key az/cidr): the route table, destination CIDR and AZ firewall endpoint. The supported module leaves these AWS-created local routes untouched; a topology drift check can compare them against the live tables. Adopting them into an aws_route owner is an experiment kept in fixtures/live only."
  value       = local.nat_local_routes
}

output "firewall_endpoint_ids" {
  description = "Per-AZ firewall endpoint IDs, published only once the firewall-to-NAT forward routes, NAT return routes and logging exist, so a caller-owned default route never points at an endpoint that cannot yet forward or log."
  value       = local.firewall_endpoints
  depends_on  = [aws_route.firewall_to_nat, aws_route.nat_return, aws_route_table_association.firewall, aws_route_table_association.nat, aws_networkfirewall_logging_configuration.egress]
}

output "alert_log_group" { value = aws_cloudwatch_log_group.alert.name }
output "flow_log_group" { value = aws_cloudwatch_log_group.flow.name }

output "home_net" {
  description = "Protected source CIDRs the firewall treats as HOME_NET (cluster node, pod and external attachment subnets)."
  value       = local.home_net
}

output "firewall_arn" {
  description = "Firewall ARN, for CloudTrail/EventBridge change alerts and Security Hub Network Firewall controls."
  value       = aws_networkfirewall_firewall.egress.arn
}

output "firewall_policy_arn" {
  value = aws_networkfirewall_firewall_policy.egress.arn
}

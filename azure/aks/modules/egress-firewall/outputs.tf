output "firewall_id" {
  value = azurerm_firewall.egress.id
}

output "firewall_policy_id" {
  description = "Tier-specific child policy attached to the firewall; replaced on tier changes."
  value       = azurerm_firewall_policy.egress.id
}

output "base_firewall_policy_id" {
  description = "Stable Standard parent policy inherited by every child; rules written after cluster creation belong here so a replacement child never lacks them."
  value       = azurerm_firewall_policy.base.id
}

output "firewall_private_ip" {
  value = azurerm_firewall.egress.ip_configuration[0].private_ip_address
}

output "public_ip_addresses" {
  description = "Firewall SNAT public IPs; these are the environment's outbound IPs in managed mode."
  value       = [azurerm_public_ip.firewall.ip_address]
}

output "route_table_id" {
  value = azurerm_route_table.egress.id

  depends_on = [azurerm_route.internet, azurerm_firewall_policy_rule_collection_group.egress, azurerm_monitor_diagnostic_setting.firewall]
}

output "compiled_policy" {
  description = "Compiled rule collections exactly as sent to Azure, for plan review and tests."
  value = {
    firewall_policy_sku            = var.tier
    firewall_policy_name           = azurerm_firewall_policy.egress.name
    firewall_policy_name_prefix    = local.firewall_policy_name_prefix
    firewall_policy_base_policy_id = azurerm_firewall_policy.egress.base_policy_id
    base_firewall_policy_name      = azurerm_firewall_policy.base.name
    base_firewall_policy_sku       = azurerm_firewall_policy.base.sku
    dns_proxy_enabled              = true
    tls_inspection_enabled         = false
    network_rule_collections       = local.network_rule_collections
    application_rule_collections   = local.application_rule_collections
  }
}

output "effective_rules" {
  value = local.effective_rules
}

output "platform_baseline_version" {
  value = "${local.platform_baseline_version}+region=${var.aks_region},azure_policy=${var.azure_policy_enabled},key_vault=${var.key_vault_secrets_provider_enabled}"
}

output "log_refs" {
  value = {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.egress.id
    diagnostic_setting_id      = azurerm_monitor_diagnostic_setting.firewall.id
    retention_days             = var.log_retention_days
    categories                 = local.diagnostic_log_categories
    queries = {
      application_verdicts = "AZFWApplicationRule | project TimeGenerated, SourceIp, Fqdn, DestinationPort, Protocol, Action, RuleCollection, Rule | order by TimeGenerated desc"
      network_verdicts     = "AZFWNetworkRule | project TimeGenerated, SourceIp, DestinationIp, DestinationPort, Protocol, Action, RuleCollection, Rule | order by TimeGenerated desc"
    }
  }
}

output "exclusions" {
  value = local.exclusions
}

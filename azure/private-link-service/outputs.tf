output "private_link_service_id" {
  description = "ID of the Private Link Service. Consumers connect to it."
  value       = azurerm_private_link_service.published_load_balancer.id
}

output "private_link_service_alias" {
  description = "Alias of the Private Link Service. Consumers can also connect to it by alias."
  value       = azurerm_private_link_service.published_load_balancer.alias
}

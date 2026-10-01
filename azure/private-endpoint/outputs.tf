output "private_endpoint_id" {
  description = "ID of the private endpoint."
  value       = azurerm_private_endpoint.private_link_service.id
}

output "private_endpoint_connection_state" {
  description = "State of the connection: Approved once the Private Link Service approves it."
  value       = data.azurerm_private_endpoint_connection.private_link_service.private_service_connection[0].status
}

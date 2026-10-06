output "application_gateway" {
  description = "Configured Azure resources, not runtime health. Public DNS publication is an explicit operator cutover gate."
  value = var.enabled ? {
    version                 = 1
    id                      = azurerm_application_gateway.this[0].id
    public_ip               = azurerm_public_ip.this[0].ip_address
    public_ip_id            = azurerm_public_ip.this[0].id
    backend_ip              = var.network.backend.private_ip
    public_dns_published    = var.activation.publish_dns
    public_dns_record_names = keys(azurerm_dns_a_record.this)
    client_identity         = "application-gateway"
    proxy_protocol_enabled  = false
  } : null
}

resource "azurerm_private_endpoint" "private_link_service" {
  name                = "${var.name_prefix}-private-endpoint"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = "${var.name_prefix}-connection"
    private_connection_resource_id = var.private_link_service_id
    is_manual_connection           = true
    request_message                = "Requested by ${var.name_prefix}"
  }
}

resource "azurerm_private_dns_zone" "private_dns_zone" {
  name                = var.private_dns_zone_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "private_dns_zone" {
  name                  = "${var.name_prefix}-vnet-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.private_dns_zone.name
  virtual_network_id    = var.virtual_network_id
  registration_enabled  = false
}

resource "azurerm_private_dns_a_record" "private_dns_zone_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.private_dns_zone.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [azurerm_private_endpoint.private_link_service.private_service_connection[0].private_ip_address]
}

# Looked up by ID, which is unknown until the endpoint exists, so the first plan defers this read to apply.
data "azurerm_private_endpoint_connection" "private_link_service" {
  name                = provider::azurerm::parse_resource_id(azurerm_private_endpoint.private_link_service.id).resource_name
  resource_group_name = var.resource_group_name
}

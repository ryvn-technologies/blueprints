resource "azurerm_postgresql_flexible_server_active_directory_administrator" "this" {
  for_each = var.entra_authentication_enabled ? var.entra_administrators : {}

  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = var.resource_group_name
  tenant_id           = var.entra_tenant_id
  object_id           = each.value.object_id
  principal_name      = each.value.principal_name
  principal_type      = each.value.principal_type
}

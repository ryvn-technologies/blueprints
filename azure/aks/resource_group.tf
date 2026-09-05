resource "azurerm_resource_group" "rg" {
  location = var.location
  name     = "ryvn-rg-${var.environment_name}"
  tags     = local.tags
}

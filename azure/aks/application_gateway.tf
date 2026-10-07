variable "application_gateway_name" {
  description = "Stable AppGW resource name; null defaults to appgw-<environment_name>. Existing Azure resources require reviewed state transfer/import."
  type        = string
  default     = null
}

locals {
  application_gateway_network = {
    version             = 2
    resource_group_name = azurerm_resource_group.rg.name
    location            = var.location
    subnet_id           = local.resolved_appgw_subnet_id
    subnet_cidr         = local.infrastructure_subnet_cidrs[index(local.infrastructure_subnet_names, "appgw-subnet")]
    backend = local.ingress_frontend_enabled ? {
      subnet_id   = azurerm_subnet.ingress_frontend[0].id
      subnet_name = azurerm_subnet.ingress_frontend[0].name
      subnet_cidr = local.ingress_frontend_cidr
      private_ip  = local.ingress_frontend_ip
    } : null
  }
}

module "application_gateway" {
  source  = "./modules/application-gateway"
  enabled = local.ingress_frontend_enabled
  name    = coalesce(var.application_gateway_name, "appgw-${var.environment_name}")
  network = local.ingress_frontend_enabled ? local.application_gateway_network : null
  tags    = local.tags
}

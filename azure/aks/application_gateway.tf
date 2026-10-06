variable "application_gateway_name" {
  description = "Stable AppGW resource name; null defaults to appgw-<environment_name>. Existing Azure resources require reviewed state transfer/import."
  type        = string
  default     = null
}

variable "application_gateway_public_dns" {
  description = "Exact A record names in the platform public zone. Null creates no records; publication requires application_gateway_activation gates."
  type = object({
    record_names = set(string)
    ttl          = optional(number, 30)
  })
  default = null
}

variable "application_gateway_activation" {
  description = "Operator attestations for a later platform DNS apply after Helm deployment and runtime checks. Infrastructure creation does not wait for backend health."
  type = object({
    publish_dns               = optional(bool, false)
    dns_owner_released        = optional(bool, false)
    backend_healthy           = optional(bool, false)
    tls_routes_ready          = optional(bool, false)
    firewall_self_calls_ready = optional(bool, false)
  })
  default = {}
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
  source     = "./modules/application-gateway"
  enabled    = local.ingress_frontend_enabled
  name       = coalesce(var.application_gateway_name, "appgw-${var.environment_name}")
  network    = local.ingress_frontend_enabled ? local.application_gateway_network : null
  tags       = local.tags
  activation = var.application_gateway_activation
  public_dns = var.application_gateway_public_dns == null ? null : {
    resource_group_name = azurerm_resource_group.rg.name
    zone_name           = azurerm_dns_zone.public.name
    record_names        = var.application_gateway_public_dns.record_names
    ttl                 = var.application_gateway_public_dns.ttl
  }
}

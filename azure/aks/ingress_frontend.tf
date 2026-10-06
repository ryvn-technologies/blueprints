variable "application_gateway_enabled" {
  description = "Provision AppGW and its dedicated ingress-LB frontend subnet/planned IP. Independent of egress_firewall.enabled; requires the existing external gateway for public ingress."
  type        = bool
  default     = false
  validation {
    condition     = !var.application_gateway_enabled || local.ingress_frontend_supported
    error_message = "Application Gateway requires at least six infrastructure slots and an unchanged AppGW subnet of /24 or larger. This VNet size cannot support the feature; supply a supported reserved range rather than re-carving existing subnets."
  }
}

locals {
  ingress_frontend_supported = local.infrastructure_subnet_newbits >= 3 && local.vnet_prefix_length + 1 + local.infrastructure_subnet_newbits <= 24
  ingress_frontend_enabled   = var.application_gateway_enabled && local.ingress_frontend_supported
  ingress_frontend_cidr      = local.ingress_frontend_enabled ? cidrsubnet(local.infrastructure_cidr, local.infrastructure_subnet_newbits, 5) : null
  ingress_frontend_ip        = local.ingress_frontend_enabled ? cidrhost(local.ingress_frontend_cidr, 4) : null
}

resource "azurerm_subnet" "ingress_frontend" {
  count                           = local.ingress_frontend_enabled ? 1 : 0
  name                            = "ingress-lb-subnet"
  resource_group_name             = local.resolved_vnet_rg
  virtual_network_name            = local.resolved_vnet_name
  address_prefixes                = [local.ingress_frontend_cidr]
  default_outbound_access_enabled = false
}

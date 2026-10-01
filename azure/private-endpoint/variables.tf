variable "location" {
  description = "Region of the VNet. The Private Link Service can be in another region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create the private endpoint and private DNS zone in."
  type        = string
}

variable "virtual_network_id" {
  description = "VNet that gets the endpoint. The private DNS zone is linked to it."
  type        = string
}

variable "subnet_id" {
  description = "Subnet of the VNet that the private endpoint takes its IP address from."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for the names of the resources this module creates."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name_prefix)) && length(var.name_prefix) <= 47
    error_message = "name_prefix must use lowercase letters, digits and hyphens, start with a letter, end with a letter or digit, and be at most 47 characters."
  }
}

variable "private_link_service_id" {
  description = "ID of the Private Link Service to connect to (/subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.Network/privateLinkServices/<name>)."
  type        = string

  validation {
    condition     = try(provider::azurerm::parse_resource_id(var.private_link_service_id).full_resource_type, "") == "Microsoft.Network/privateLinkServices"
    error_message = "private_link_service_id must look like /subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.Network/privateLinkServices/<name>."
  }
}

variable "private_dns_zone_name" {
  description = "Private DNS zone to create and link to the VNet, without a trailing dot. Every name under it resolves to the endpoint."
  type        = string

  validation {
    condition     = var.private_dns_zone_name == lower(var.private_dns_zone_name) && !endswith(var.private_dns_zone_name, ".")
    error_message = "private_dns_zone_name must be lowercase, without a trailing dot."
  }
}

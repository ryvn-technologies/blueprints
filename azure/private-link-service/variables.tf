variable "location" {
  description = "Region to create the Private Link Service in. The load balancer and NAT subnet must be in the same region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create the Private Link Service in."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for the names of the resources this module creates."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name_prefix))
    error_message = "name_prefix must use lowercase letters, digits and hyphens, start with a letter and end with a letter or digit."
  }
}

variable "load_balancer_name" {
  description = "Name of the Standard Load Balancer that has the frontend to publish."
  type        = string
}

variable "load_balancer_resource_group_name" {
  description = "Resource group of the load balancer. Leave unset with kubernetes_service, which uses the cluster's node resource group."
  type        = string
  default     = null

  validation {
    condition     = (var.load_balancer_resource_group_name == null) != (var.kubernetes_service == null)
    error_message = "Set load_balancer_resource_group_name, or kubernetes_service to use the cluster's node resource group."
  }
}

variable "frontend_ip_configuration_name" {
  description = "Name of the load balancer frontend to publish. Set this or kubernetes_service."
  type        = string
  default     = null
}

variable "kubernetes_service" {
  description = "LoadBalancer Service on an AKS cluster, with the cluster's resource ID. The frontend with the Service's load balancer IP gets published. Set this or frontend_ip_configuration_name."
  type = object({
    cluster_id = string
    namespace  = string
    name       = string
  })
  default = null

  validation {
    condition     = (var.kubernetes_service == null) != (var.frontend_ip_configuration_name == null)
    error_message = "Set exactly one of frontend_ip_configuration_name or kubernetes_service."
  }

  validation {
    condition     = var.kubernetes_service == null || try(provider::azurerm::parse_resource_id(var.kubernetes_service.cluster_id).full_resource_type, "") == "Microsoft.ContainerService/managedClusters"
    error_message = "kubernetes_service.cluster_id must be an AKS cluster resource ID."
  }
}

variable "virtual_network_id" {
  description = "VNet of the load balancer frontend. The NAT subnet is created in it."
  type        = string

  validation {
    condition     = try(provider::azurerm::parse_resource_id(var.virtual_network_id).full_resource_type, "") == "Microsoft.Network/virtualNetworks"
    error_message = "virtual_network_id must be an Azure VNet resource ID."
  }
}

variable "nat_subnet_address_range" {
  description = "Free address range in the VNet to create the NAT subnet in. The subnet takes its first /28, so this can be a larger range set aside for service subnets."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.nat_subnet_address_range)) && try(tonumber(split("/", var.nat_subnet_address_range)[1]) <= 28, false)
    error_message = "nat_subnet_address_range must be an IPv4 range of /28 or larger, such as 10.0.4.0/28."
  }
}

variable "visibility_subscription_ids" {
  description = "Subscription IDs that can find and connect to the Private Link Service. Empty allows only this subscription."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for id in var.visibility_subscription_ids : can(regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", id))])
    error_message = "visibility_subscription_ids must be subscription IDs, such as 00000000-0000-0000-0000-000000000000."
  }
}

variable "auto_approval_subscription_ids" {
  description = "Subscription IDs whose connections are approved automatically. Connections from other subscriptions wait for manual approval."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for id in var.auto_approval_subscription_ids : can(regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", id))])
    error_message = "auto_approval_subscription_ids must be subscription IDs, such as 00000000-0000-0000-0000-000000000000."
  }
}

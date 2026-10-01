data "azurerm_client_config" "current" {}

data "azurerm_kubernetes_cluster" "published" {
  count = var.kubernetes_service == null ? 0 : 1

  name                = provider::azurerm::parse_resource_id(var.kubernetes_service.cluster_id).resource_name
  resource_group_name = provider::azurerm::parse_resource_id(var.kubernetes_service.cluster_id).resource_group_name
}

data "azurerm_lb" "published" {
  name                = var.load_balancer_name
  resource_group_name = var.kubernetes_service == null ? var.load_balancer_resource_group_name : data.azurerm_kubernetes_cluster.published[0].node_resource_group
}

data "kubernetes_service_v1" "published" {
  count = var.kubernetes_service == null ? 0 : 1

  metadata {
    namespace = var.kubernetes_service.namespace
    name      = var.kubernetes_service.name
  }
}

locals {
  virtual_network = provider::azurerm::parse_resource_id(var.virtual_network_id)

  service_ingress_ips = var.kubernetes_service == null ? [] : compact(flatten([
    for status in try(data.kubernetes_service_v1.published[0].status, []) : [
      for load_balancer in try(status.load_balancer, []) : [
        for ingress in try(load_balancer.ingress, []) : try(ingress.ip, null)
      ]
    ]
  ]))

  published_frontends = [
    for frontend in data.azurerm_lb.published.frontend_ip_configuration : frontend
    if(
      var.frontend_ip_configuration_name != null
      ? frontend.name == var.frontend_ip_configuration_name
      : contains(local.service_ingress_ips, try(frontend.private_ip_address, ""))
    )
  ]
}

resource "azurerm_subnet" "private_link_service_nat" {
  name                 = "${var.name_prefix}-nat"
  resource_group_name  = local.virtual_network.resource_group_name
  virtual_network_name = local.virtual_network.resource_name
  address_prefixes     = [cidrsubnet(var.nat_subnet_address_range, 28 - tonumber(split("/", var.nat_subnet_address_range)[1]), 0)]

  private_link_service_network_policies_enabled = false
}

resource "azurerm_private_link_service" "published_load_balancer" {
  name                = var.name_prefix
  location            = var.location
  resource_group_name = var.resource_group_name

  load_balancer_frontend_ip_configuration_ids = [
    for frontend in local.published_frontends : frontend.id
  ]

  nat_ip_configuration {
    name                       = "${var.name_prefix}-nat"
    primary                    = true
    private_ip_address_version = "IPv4"
    subnet_id                  = azurerm_subnet.private_link_service_nat.id
  }

  visibility_subscription_ids    = [for id in coalescelist(var.visibility_subscription_ids, [data.azurerm_client_config.current.subscription_id]) : lower(id)]
  auto_approval_subscription_ids = [for id in var.auto_approval_subscription_ids : lower(id)]
  proxy_protocol_enabled         = false

  lifecycle {
    precondition {
      condition     = lower(data.azurerm_lb.published.sku) == "standard"
      error_message = "load_balancer_name must be a Standard SKU load balancer."
    }

    precondition {
      condition     = var.kubernetes_service == null || length(local.service_ingress_ips) > 0
      error_message = "kubernetes_service has no load balancer IP yet."
    }

    precondition {
      condition     = length(local.published_frontends) == 1
      error_message = var.kubernetes_service == null ? "load_balancer_name has no frontend named frontend_ip_configuration_name." : "Exactly one frontend of load_balancer_name must have the load balancer IP of kubernetes_service."
    }
  }
}

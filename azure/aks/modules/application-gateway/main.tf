data "azurerm_subnet" "appgw" {
  count                = var.enabled ? 1 : 0
  name                 = provider::azurerm::parse_resource_id(var.network.subnet_id).resource_name
  virtual_network_name = provider::azurerm::parse_resource_id(var.network.subnet_id).parent_resources["virtualNetworks"]
  resource_group_name  = provider::azurerm::parse_resource_id(var.network.subnet_id).resource_group_name
}

data "azurerm_subnet" "backend" {
  count                = var.enabled ? 1 : 0
  name                 = var.network.backend.subnet_name
  virtual_network_name = provider::azurerm::parse_resource_id(var.network.backend.subnet_id).parent_resources["virtualNetworks"]
  resource_group_name  = provider::azurerm::parse_resource_id(var.network.backend.subnet_id).resource_group_name
}

locals {
  nsg_id = var.enabled ? "/subscriptions/${provider::azurerm::parse_resource_id(var.network.subnet_id).subscription_id}/resourceGroups/${var.network.resource_group_name}/providers/Microsoft.Network/networkSecurityGroups/nsg-${var.name}" : ""
  rules = var.enabled ? {
    public-tcp = {
      priority = 100, protocol = "Tcp", source = "Internet", destination = var.network.subnet_cidr, ports = ["80", "443"], access = "Allow"
    }
    gateway-manager = {
      priority = 110, protocol = "Tcp", source = "GatewayManager", destination = "*", ports = ["65200-65535"], access = "Allow"
    }
    azure-health = {
      priority = 120, protocol = "*", source = "AzureLoadBalancer", destination = "*", ports = ["*"], access = "Allow"
    }
    gateway-subnet = {
      priority = 130, protocol = "*", source = var.network.subnet_cidr, destination = var.network.subnet_cidr, ports = ["*"], access = "Allow"
    }
    deny-other-inbound = {
      priority = 140, protocol = "*", source = "*", destination = "*", ports = ["*"], access = "Deny"
    }
  } : {}
}

resource "azurerm_public_ip" "this" {
  count                   = var.enabled ? 1 : 0
  name                    = "pip-${var.name}"
  resource_group_name     = var.network.resource_group_name
  location                = var.network.location
  allocation_method       = "Static"
  sku                     = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
  lifecycle { prevent_destroy = true }
}

resource "azurerm_network_security_group" "this" {
  count               = var.enabled ? 1 : 0
  name                = "nsg-${var.name}"
  resource_group_name = var.network.resource_group_name
  location            = var.network.location
  tags                = var.tags
  dynamic "security_rule" {
    for_each = local.rules
    content {
      name                       = security_rule.key
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = security_rule.value.access
      protocol                   = security_rule.value.protocol
      source_port_range          = "*"
      destination_port_range     = length(security_rule.value.ports) == 1 ? one(security_rule.value.ports) : null
      destination_port_ranges    = length(security_rule.value.ports) > 1 ? security_rule.value.ports : null
      source_address_prefix      = security_rule.value.source
      destination_address_prefix = security_rule.value.destination
    }
  }
  lifecycle { prevent_destroy = true }
}

resource "azurerm_subnet_network_security_group_association" "this" {
  count                     = var.enabled ? 1 : 0
  subnet_id                 = var.network.subnet_id
  network_security_group_id = azurerm_network_security_group.this[0].id
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = data.azurerm_subnet.appgw[0].network_security_group_id == "" || lower(data.azurerm_subnet.appgw[0].network_security_group_id) == lower(local.nsg_id)
      error_message = "AppGW subnet already has a foreign NSG. Do not replace or adopt it automatically."
    }
    precondition {
      condition     = data.azurerm_subnet.appgw[0].route_table_id == "" && toset(data.azurerm_subnet.appgw[0].address_prefixes) == toset([var.network.subnet_cidr])
      error_message = "AppGW requires its declared dedicated subnet with no route-table association; keep the Firewall UDR on workload subnets only."
    }
  }
}

resource "azurerm_application_gateway" "this" {
  count               = var.enabled ? 1 : 0
  name                = var.name
  resource_group_name = var.network.resource_group_name
  location            = var.network.location
  tags                = var.tags
  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }
  autoscale_configuration {
    min_capacity = 1
    max_capacity = 2
  }
  gateway_ip_configuration {
    name      = "gateway"
    subnet_id = var.network.subnet_id
  }
  frontend_ip_configuration {
    name                 = "public"
    public_ip_address_id = azurerm_public_ip.this[0].id
  }
  backend_address_pool {
    name         = "istio-private"
    ip_addresses = [var.network.backend.private_ip]
  }
  dynamic "frontend_port" {
    for_each = toset(["80", "443"])
    content {
      name = "tcp-${frontend_port.value}"
      port = tonumber(frontend_port.value)
    }
  }
  dynamic "listener" {
    for_each = toset(["80", "443"])
    content {
      name                           = "tcp-${listener.value}"
      frontend_ip_configuration_name = "public"
      frontend_port_name             = "tcp-${listener.value}"
      protocol                       = "Tcp"
    }
  }
  dynamic "backend" {
    for_each = toset(["80", "443"])
    content {
      name                           = "tcp-${backend.value}"
      port                           = tonumber(backend.value)
      protocol                       = "Tcp"
      timeout_in_seconds             = 600
      client_ip_preservation_enabled = false
      probe_name                     = "tcp-${backend.value}"
    }
  }
  dynamic "probe" {
    for_each = toset(["80", "443"])
    content {
      name                          = "tcp-${probe.value}"
      protocol                      = "Tcp"
      port                          = tonumber(probe.value)
      interval                      = probe.value == "80" ? 21 : 20
      timeout                       = 10
      unhealthy_threshold           = 3
      proxy_protocol_header_enabled = false
    }
  }
  dynamic "routing_rule" {
    for_each = toset(["80", "443"])
    content {
      name                      = "tcp-${routing_rule.value}"
      listener_name             = "tcp-${routing_rule.value}"
      backend_address_pool_name = "istio-private"
      backend_name              = "tcp-${routing_rule.value}"
      priority                  = tonumber(routing_rule.value)
    }
  }
  depends_on = [azurerm_subnet_network_security_group_association.this]
  lifecycle {
    prevent_destroy = true
    precondition {
      condition = try(
        toset(data.azurerm_subnet.backend[0].address_prefixes) == toset([var.network.backend.subnet_cidr]) &&
        data.azurerm_subnet.backend[0].route_table_id == "" &&
        lower(trimsuffix(var.network.backend.subnet_id, "/subnets/${var.network.backend.subnet_name}")) == lower(trimsuffix(var.network.subnet_id, "/subnets/${provider::azurerm::parse_resource_id(var.network.subnet_id).resource_name}")), false
      )
      error_message = "The dedicated ingress-LB frontend subnet must match the platform contract, share the AppGW VNet and have no egress route-table association."
    }
  }
}

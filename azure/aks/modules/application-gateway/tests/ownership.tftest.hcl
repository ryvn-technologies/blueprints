mock_provider "azurerm" {}

variables {
  name = "appgw-test"
  network = {
    version             = 2
    resource_group_name = "rg"
    location            = "centralus"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/appgw-subnet"
    subnet_cidr         = "10.12.128.0/24"
    backend = {
      subnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/ingress-lb-subnet"
      subnet_name = "ingress-lb-subnet"
      subnet_cidr = "10.12.133.0/24"
      private_ip  = "10.12.133.4"
    }
  }
}

override_data {
  target = data.azurerm_subnet.backend[0]
  values = {
    address_prefixes     = ["10.12.133.0/24"]
    route_table_id       = ""
    virtual_network_name = "vnet"
  }
}

override_data {
  target = data.azurerm_subnet.appgw[0]
  values = {
    address_prefixes          = ["10.12.128.0/24"]
    network_security_group_id = ""
    route_table_id            = ""
    virtual_network_name      = "vnet"
  }
}

run "disabled_has_no_resources" {
  command = plan
  assert {
    condition     = length(azurerm_application_gateway.this) == 0 && length(azurerm_public_ip.this) == 0 && length(azurerm_network_security_group.this) == 0 && length(azurerm_subnet_network_security_group_association.this) == 0 && output.application_gateway == null
    error_message = "Disabled and omitted input must not create network or DNS resources."
  }
}

run "enabled_before_kubernetes_exists" {
  command = plan
  variables { enabled = true }
  assert {
    condition     = length(azurerm_application_gateway.this) == 1 && length(azurerm_public_ip.this) == 1 && length(azurerm_network_security_group.this) == 1
    error_message = "Enabled mode must render the AppGW, public IP and dedicated NSG."
  }
  assert {
    condition     = output.application_gateway.proxy_protocol_enabled == false && output.application_gateway.client_identity == "application-gateway"
    error_message = "Stage 1 must expose AppGW identity with PROXY disabled."
  }
  assert {
    condition     = one(azurerm_application_gateway.this[0].backend_address_pool).ip_addresses == toset(["10.12.133.4"]) && alltrue([for probe in azurerm_application_gateway.this[0].probe : probe.protocol == "Tcp" && !probe.proxy_protocol_header_enabled]) && azurerm_public_ip.this[0].idle_timeout_in_minutes == 10
    error_message = "AppGW must configure the planned IP without Kubernetes reads or automatic DNS cutover."
  }
}

run "accept_owned_nsg_in_platform_group_with_existing_vnet" {
  command = plan
  variables {
    enabled = true
    network = {
      version             = 2
      resource_group_name = "platform-rg"
      location            = "centralus"
      subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/appgw-subnet"
      subnet_cidr         = "10.12.128.0/24"
      backend = {
        subnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/ingress-lb-subnet"
        subnet_name = "ingress-lb-subnet"
        subnet_cidr = "10.12.133.0/24"
        private_ip  = "10.12.133.4"
      }
    }
  }
  override_data {
    target = data.azurerm_subnet.appgw[0]
    values = {
      address_prefixes          = ["10.12.128.0/24"]
      network_security_group_id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/platform-rg/providers/Microsoft.Network/networkSecurityGroups/nsg-appgw-test"
      route_table_id            = ""
      virtual_network_name      = "vnet"
    }
  }
  assert {
    condition     = length(azurerm_subnet_network_security_group_association.this) == 1
    error_message = "The association must recognize its owned NSG even when the VNet is in a different resource group."
  }
}

run "reject_different_vnet_with_same_name" {
  command = plan
  variables {
    enabled = true
    network = {
      version             = 2
      resource_group_name = "rg"
      location            = "centralus"
      subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/appgw-subnet"
      subnet_cidr         = "10.12.128.0/24"
      backend = {
        subnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/other-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/ingress-lb-subnet"
        subnet_name = "ingress-lb-subnet"
        subnet_cidr = "10.12.133.0/24"
        private_ip  = "10.12.133.4"
      }
    }
  }
  expect_failures = [azurerm_application_gateway.this]
}

run "reject_foreign_subnet_nsg" {
  command = plan
  variables { enabled = true }
  override_data {
    target = data.azurerm_subnet.appgw[0]
    values = { network_security_group_id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/foreign" }
  }
  expect_failures = [azurerm_subnet_network_security_group_association.this]
}

run "reject_forced_tunnel_appgw_subnet" {
  command = plan
  variables { enabled = true }
  override_data {
    target = data.azurerm_subnet.appgw[0]
    values = { route_table_id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/routeTables/forced-tunnel" }
  }
  expect_failures = [azurerm_subnet_network_security_group_association.this]
}

run "reject_forced_tunnel_frontend_subnet" {
  command = plan
  variables { enabled = true }
  override_data {
    target = data.azurerm_subnet.backend[0]
    values = { address_prefixes = ["10.12.133.0/24"], route_table_id = "forced-tunnel" }
  }
  expect_failures = [azurerm_application_gateway.this]
}

run "reject_nonplanned_backend_address" {
  command = plan
  variables {
    enabled = true
    network = {
      version             = 2
      resource_group_name = "rg"
      location            = "centralus"
      subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/appgw-subnet"
      subnet_cidr         = "10.12.128.0/24"
      backend = {
        subnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/ingress-lb-subnet"
        subnet_name = "ingress-lb-subnet"
        subnet_cidr = "10.12.133.0/24"
        private_ip  = "10.12.133.5"
      }
    }
  }
  expect_failures = [var.network]
}

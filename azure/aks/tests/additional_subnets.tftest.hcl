mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      client_id       = "00000000-0000-0000-0000-000000000001"
      object_id       = "00000000-0000-0000-0000-000000000002"
      subscription_id = "00000000-0000-0000-0000-000000000003"
      tenant_id       = "00000000-0000-0000-0000-000000000004"
    }
  }
  mock_data "azurerm_subscription" {
    defaults = {
      id              = "/subscriptions/00000000-0000-0000-0000-000000000003"
      subscription_id = "00000000-0000-0000-0000-000000000003"
      tenant_id       = "00000000-0000-0000-0000-000000000004"
    }
  }
  mock_data "azurerm_virtual_network" {
    defaults = {
      id                  = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet"
      name                = "vnet"
      resource_group_name = "rg"
      location            = "eastus2"
      address_space       = ["10.0.0.0/16"]
      guid                = "00000000-0000-0000-0000-000000000005"
    }
  }
}
mock_provider "azapi" {}
mock_provider "local" {}
mock_provider "null" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  environment_name     = "egress-groups"
  location             = "eastus2"
  public_root_domain   = "test.example.com"
  internal_root_domain = "test.internal"
  zones                = ["1"]
  vnet_cidr            = "10.0.0.0/21"
  additional_subnet_groups = [
    { name = "first", ipv4_prefix_length = 25 },
    { name = "second", ipv4_prefix_length = 26 },
  ]
}

run "disabled_groups_have_drop_routes" {
  command = plan
  assert {
    condition     = length(module.egress_firewall) == 0 && azurerm_route.additional_group_default["first"].next_hop_type == "None" && azurerm_subnet.additional_group["first"].default_outbound_access_enabled == false
    error_message = "Unattached subnets must have a default drop route and no implicit Azure outbound access even without a firewall."
  }
  assert {
    condition     = output.additional_subnet_groups["first"].ipv4_cidr == "10.0.3.0/25" && output.additional_subnet_groups["second"].ipv4_cidr == "10.0.3.128/26" && length(output.egress_firewall.attachments) == 0
    error_message = "Groups must allocate sequentially inside the fixed fourth quarter without enabling the firewall."
  }
}

run "flat_layout_uses_same_fixed_region" {
  command = plan
  variables { network_plugin_mode = "flat" }
  assert {
    condition     = output.additional_subnet_groups["first"].ipv4_cidr == "10.0.3.0/25" && local.node_pool_subnet_cidrs[2] == "10.0.0.128/26"
    error_message = "Flat mode keeps existing cluster subnets and allocates external groups from the same free region."
  }
}

run "reject_allocation_exhaustion" {
  command = plan
  variables {
    additional_subnet_groups = [
      { name = "first", ipv4_prefix_length = 24 },
      { name = "second", ipv4_prefix_length = 26 },
    ]
  }
  expect_failures = [terraform_data.additional_subnet_contract]
}

run "reject_unknown_attachment" {
  command = plan
  variables {
    egress_attachments = { outside = { subnet_group_key = "unknown", policy_key = "cluster" } }
  }
  expect_failures = [var.egress_attachments]
}

run "attached_group_uses_firewall_route" {
  command = plan
  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {}
        workers = { domain_allow = { jobs = { domains = ["jobs.example.com"], protocol = "https" } } }
      }
    }
    egress_attachments = { workers = { subnet_group_key = "first", policy_key = "workers" } }
  }
  assert {
    condition     = azurerm_route.additional_group_default["first"].next_hop_type == "VirtualAppliance" && azurerm_route.additional_group_default["second"].next_hop_type == "None" && output.egress_firewall.attachments["workers"].subnet_group_key == "first"
    error_message = "Only the attached group gets a firewall default route and attachment descriptor."
  }
  assert {
    condition     = output.additional_subnet_groups["first"].ipv4_cidr == "10.0.3.0/25" && output.additional_subnet_groups["second"].ipv4_cidr == "10.0.3.128/26"
    error_message = "Attaching one group must not change either group's allocation."
  }
}

run "reassign_group_without_changing_allocation" {
  command = plan
  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {}
        workers = { domain_allow = { jobs = { domains = ["jobs.example.com"], protocol = "https" } } }
      }
    }
    egress_attachments = { workers = { subnet_group_key = "second", policy_key = "workers" } }
  }
  assert {
    condition     = azurerm_route.additional_group_default["first"].next_hop_type == "None" && azurerm_route.additional_group_default["second"].next_hop_type == "VirtualAppliance" && output.egress_firewall.attachments["workers"].ipv4_cidr == "10.0.3.128/26"
    error_message = "Reassignment moves the attachment and firewall route, not the allocated CIDRs."
  }
}

run "retire_after_detaching" {
  command = plan
  variables {
    additional_subnet_groups = [
      { name = "first", ipv4_prefix_length = 25, retired = true },
      { name = "second", ipv4_prefix_length = 26 },
      { name = "third", ipv4_prefix_length = 26 },
    ]
  }
  assert {
    condition     = !contains(keys(azurerm_subnet.additional_group), "first") && contains(keys(terraform_data.additional_subnet_geometry), "first") && terraform_data.additional_subnet_ledger["first"].input.retired && output.additional_subnet_groups["second"].ipv4_cidr == "10.0.3.128/26" && output.additional_subnet_groups["third"].ipv4_cidr == "10.0.3.192/26"
    error_message = "Retiring removes the subnet, preserves its range as a tombstone, and allows only append allocations."
  }
}

run "reject_duplicate_group_attachments" {
  command = plan
  variables {
    egress_attachments = {
      one = { subnet_group_key = "first", policy_key = "cluster" }
      two = { subnet_group_key = "first", policy_key = "cluster" }
    }
  }
  expect_failures = [var.egress_attachments]
}

run "reject_external_allocation_inside_unowned_vnet" {
  command = plan
  variables {
    existing_vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet"
  }
  expect_failures = [var.additional_subnet_groups]
}

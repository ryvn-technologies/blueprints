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

  # The runs below `apply` against mocks; azurerm validates ID/scope
  # shapes client-side, so computed IDs consumed by other resources need real shapes.
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/AzureFirewallSubnet" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip" }
  }
  mock_resource "azurerm_firewall" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/azureFirewalls/afw" }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law" }
  }
  mock_resource "azurerm_route_table" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/routeTables/rt" }
  }
  mock_resource "azurerm_dns_zone" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/dnszones/zone" }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/zone" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai" }
  }
  mock_resource "azurerm_firewall_policy" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/firewallPolicies/afwp" }
  }
  # The base (parent) policy needs a distinct ID so tests can tell which policy a
  # rule collection group was written to.
  override_resource {
    target = module.egress_firewall[0].azurerm_firewall_policy.base
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/firewallPolicies/afwp-base" }
  }
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      oidc_issuer_url        = "https://eastus2.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000004/00000000-0000-0000-0000-000000000006/"
      node_resource_group    = "MC_rg_aks_eastus2"
      node_resource_group_id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/MC_rg_aks_eastus2"
      id                     = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks"
      kube_config = [{
        host                   = "https://aks.example:443"
        username               = ""
        password               = ""
        client_certificate     = ""
        client_key             = ""
        cluster_ca_certificate = ""
      }]
    }
  }
}

mock_provider "azapi" {
  # Node resource group listing as returned by Azure: the AKS-managed outbound IP is
  # tagged, an inbound Service IP in the same group is not.
  mock_data "azapi_resource_list" {
    defaults = {
      output = {
        value = [
          {
            name       = "00000000-0000-0000-0000-00000000aaaa"
            tags       = { "aks-managed-type" = "aks-slb-managed-outbound-ip" }
            properties = { ipAddress = "203.0.113.10" }
          },
          {
            name       = "kubernetes-a1b2c3"
            tags       = { "kubernetes-cluster-name" = "kubernetes" }
            properties = { ipAddress = "203.0.113.20" }
          },
        ]
      }
    }
  }
}
mock_provider "local" {}
mock_provider "null" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  environment_name     = "egress-fw-test"
  location             = "eastus2"
  public_root_domain   = "test.example.com"
  internal_root_domain = "test.internal"
  zones                = ["1"]

  egress_firewall = {
    enabled            = true
    default_action     = "deny"
    cluster_policy_key = "cluster"
    policies = {
      cluster = {
        domain_allow = {
          https = { domains = ["api.vendor.example", "*.customer.example"], protocol = "https" }
          http  = { domains = ["mirror.customer.example"], protocol = "http" }
        }
        network_allow = {
          smtp_relay = {
            destination_ipv4_cidrs = ["8.8.8.0/24"]
            protocol               = "tcp"
            destination_ports      = [587]
            reason                 = "Outbound SMTP relay pinned by IP"
          }
        }
      }
      workers = {
        domain_allow = {
          https = { domains = ["api.vendor.example", "*.customer.example"], protocol = "https" }
        }
      }
    }
  }

  additional_subnet_groups = [{ name = "api_clients", ipv4_prefix_length = 24 }]
  egress_attachments = {
    api_clients = { policy_key = "workers", subnet_group_key = "api_clients" }
  }
}

# ---------------------------------------------------------------------------
# Lifecycle: enabled -> disabled -> enabled with ordinary plan/apply
# ---------------------------------------------------------------------------

run "lifecycle_apply_enabled" {
  command = apply

  assert {
    condition     = module.aks.network_profile[0].outbound_type == "userDefinedRouting"
    error_message = "Enabled apply must leave AKS in userDefinedRouting."
  }

  # Fresh construction: the tier-specific child policy inherits a stable Standard
  # base policy, and the post-creation API-server group is written to the base, not
  # to the child that tier changes replace.
  assert {
    condition     = output.egress_firewall.compiled_policy.base_firewall_policy_sku == "Standard" && output.egress_firewall.compiled_policy.base_firewall_policy_name == "afwp-egress-fw-test-egress-base"
    error_message = "The base policy must be a Standard policy with a stable, tier-independent name."
  }

  assert {
    condition     = output.egress_firewall.compiled_policy.firewall_policy_base_policy_id == output.egress_firewall.enforcement_refs.base_firewall_policy_id && output.egress_firewall.enforcement_refs.base_firewall_policy_id != output.egress_firewall.policy_ref
    error_message = "The attached child policy must inherit from the base policy, and the base must be a different policy from the attached one."
  }

  assert {
    condition     = azurerm_firewall_policy_rule_collection_group.api_server[0].firewall_policy_id == output.egress_firewall.enforcement_refs.base_firewall_policy_id
    error_message = "The API-server rule collection group must be written to the base policy so every child inherits it."
  }
}

# Prior state still carries the UDR-era AKS profile with no effective outbound IPs, so
# the LB outbound lookup must not index into it while the outbound type flips.
run "lifecycle_disable_plans_from_udr_state" {
  command = plan

  variables {
    egress_firewall    = {}
    egress_attachments = {}
  }

  assert {
    condition     = module.aks.network_profile[0].outbound_type == "loadBalancer"
    error_message = "Disabling must plan AKS back to loadBalancer outbound."
  }

  assert {
    condition     = length(module.egress_firewall) == 0 && length(azurerm_subnet_route_table_association.egress_node_pool) == 0
    error_message = "Disabling must remove the firewall and its node-pool route associations."
  }
}

run "lifecycle_disable_applies_from_udr_state" {
  command = apply

  variables {
    egress_firewall    = {}
    egress_attachments = {}
  }

  assert {
    condition     = module.aks.network_profile[0].outbound_type == "loadBalancer" && output.egress_firewall.enabled == false
    error_message = "Disabled apply must leave AKS in loadBalancer outbound with enforcement removed."
  }

  assert {
    condition     = tolist(output.outbound_ips) == tolist(["203.0.113.10"])
    error_message = "Disabled apply must publish only the AKS-managed outbound IP from the node resource group (not Service IPs, not an empty list)."
  }
}

run "lifecycle_reenable_plans_from_lb_state" {
  command = plan

  assert {
    condition     = module.aks.network_profile[0].outbound_type == "userDefinedRouting" && length(module.egress_firewall) == 1
    error_message = "Re-enabling from loadBalancer state must plan UDR and recreate the firewall."
  }
}

run "lifecycle_reenable_applies_from_lb_state" {
  command = apply

  assert {
    condition     = module.aks.network_profile[0].outbound_type == "userDefinedRouting" && output.egress_firewall.compiled_policy.firewall_policy_sku == "Standard"
    error_message = "Re-enabled apply must be back in UDR on a Standard policy."
  }
}

# ---------------------------------------------------------------------------
# Tier migration: Standard -> Premium -> Standard with the policy replaced under a
# different name while the firewall updates in place
# ---------------------------------------------------------------------------

run "tier_premium_plans_from_standard_state" {
  command = plan

  variables {
    egress_firewall = {
      enabled            = true
      tier               = "Premium"
      cluster_policy_key = "cluster"
      policies = { cluster = { domain_allow = { https = { domains = ["api.vendor.example"], protocol = "https" }
      } } }
    }
    egress_attachments = {}
  }

  assert {
    condition     = output.egress_firewall.compiled_policy.firewall_policy_sku == "Premium" && output.egress_firewall.compiled_policy.tls_inspection_enabled == false
    error_message = "Premium plan from Standard state must target a Premium policy without TLS inspection."
  }

  # Populated-state replacement: the plan must leave the base policy and the
  # API-server group in place (their IDs stay known and equal to the prior apply),
  # while the child policy is the only policy being replaced. A replaced or
  # recreated base/API-server group would make these values unknown here.
  assert {
    condition     = output.egress_firewall.enforcement_refs.base_firewall_policy_id == run.lifecycle_reenable_applies_from_lb_state.egress_firewall.enforcement_refs.base_firewall_policy_id
    error_message = "A tier change must not replace the base policy."
  }

  assert {
    condition     = azurerm_firewall_policy_rule_collection_group.api_server[0].id == run.lifecycle_reenable_applies_from_lb_state.egress_firewall.enforcement_refs.api_server_rule_collection_group_id && azurerm_firewall_policy_rule_collection_group.api_server[0].firewall_policy_id == run.lifecycle_reenable_applies_from_lb_state.egress_firewall.enforcement_refs.base_firewall_policy_id
    error_message = "A tier change must not touch the API-server rule collection group: it stays on the base policy and is inherited by the replacement child."
  }

  assert {
    condition     = output.egress_firewall.compiled_policy.firewall_policy_base_policy_id == run.lifecycle_reenable_applies_from_lb_state.egress_firewall.enforcement_refs.base_firewall_policy_id && output.egress_firewall.compiled_policy.base_firewall_policy_sku == "Standard"
    error_message = "The replacement Premium child must inherit the existing Standard base policy."
  }
}

run "tier_premium_applies_from_standard_state" {
  command = apply

  variables {
    egress_firewall = {
      enabled            = true
      tier               = "Premium"
      cluster_policy_key = "cluster"
      policies = { cluster = { domain_allow = { https = { domains = ["api.vendor.example"], protocol = "https" }
      } } }
    }
    egress_attachments = {}
  }

  assert {
    condition     = output.egress_firewall.compiled_policy.firewall_policy_sku == "Premium"
    error_message = "Premium apply must complete from Standard state."
  }

  assert {
    condition     = can(regex("^afwp-egress-fw-test-egress-premium-[0-9a-f]{4}$", output.egress_firewall.compiled_policy.firewall_policy_name)) && output.egress_firewall.compiled_policy.firewall_policy_name != run.lifecycle_reenable_applies_from_lb_state.egress_firewall.compiled_policy.firewall_policy_name
    error_message = "Premium policy must get a fresh generation-suffixed name so it can be created next to the attached Standard policy before the firewall switches."
  }

  assert {
    condition     = azurerm_firewall_policy_rule_collection_group.api_server[0].id == run.lifecycle_reenable_applies_from_lb_state.egress_firewall.enforcement_refs.api_server_rule_collection_group_id && azurerm_firewall_policy_rule_collection_group.api_server[0].firewall_policy_id == output.egress_firewall.enforcement_refs.base_firewall_policy_id && output.egress_firewall.enforcement_refs.base_firewall_policy_id != output.egress_firewall.policy_ref
    error_message = "After the switch the API-server rule collection group must be the same resource on the unchanged base policy, inherited by (not recreated under) the new Premium child."
  }
}

run "tier_standard_applies_from_premium_state" {
  command = apply

  variables {
    egress_attachments = {}
  }

  assert {
    condition     = output.egress_firewall.compiled_policy.firewall_policy_sku == "Standard"
    error_message = "Standard apply must complete from Premium state."
  }

  # A rollback must never reuse the name of the Standard policy it is replacing: with
  # create_before_destroy the retired policy still exists (and may still be attached
  # after a failed tier change) while the new one is created, so a static
  # per-tier name collides with "already exists - needs to be imported".
  assert {
    condition     = can(regex("^afwp-egress-fw-test-egress-standard-[0-9a-f]{4}$", output.egress_firewall.compiled_policy.firewall_policy_name)) && output.egress_firewall.compiled_policy.firewall_policy_name != run.lifecycle_reenable_applies_from_lb_state.egress_firewall.compiled_policy.firewall_policy_name && output.egress_firewall.compiled_policy.firewall_policy_name != run.tier_premium_applies_from_standard_state.egress_firewall.compiled_policy.firewall_policy_name
    error_message = "Rolling back to Standard must create a new generation-suffixed policy, not reuse the retired Standard or Premium policy names."
  }

  assert {
    condition     = azurerm_firewall_policy_rule_collection_group.api_server[0].id == run.lifecycle_reenable_applies_from_lb_state.egress_firewall.enforcement_refs.api_server_rule_collection_group_id && azurerm_firewall_policy_rule_collection_group.api_server[0].firewall_policy_id == output.egress_firewall.enforcement_refs.base_firewall_policy_id
    error_message = "Rolling back to Standard must leave the API-server rule collection group untouched on the base policy."
  }
}

run "append_group_keeps_populated_geometry" {
  command = apply
  variables {
    additional_subnet_groups = [
      { name = "api_clients", ipv4_prefix_length = 24 },
      { name = "batch", ipv4_prefix_length = 26 },
    ]
  }
  assert {
    condition     = terraform_data.additional_subnet_geometry["api_clients"].output.ipv4_cidr == "10.0.96.0/24" && terraform_data.additional_subnet_geometry["batch"].output.ipv4_cidr == "10.0.97.0/26"
    error_message = "Append must retain the applied group's range and allocate a new sequential range."
  }
}

run "resize_group_fails_against_populated_state" {
  command = plan
  variables {
    additional_subnet_groups = [
      { name = "api_clients", ipv4_prefix_length = 25 },
      { name = "batch", ipv4_prefix_length = 26 },
    ]
  }
  expect_failures = [terraform_data.additional_subnet_geometry["api_clients"], terraform_data.additional_subnet_geometry["batch"]]
}

run "reorder_groups_fails_against_populated_state" {
  command = plan
  variables {
    additional_subnet_groups = [
      { name = "batch", ipv4_prefix_length = 26 },
      { name = "api_clients", ipv4_prefix_length = 24 },
    ]
  }
  expect_failures = [terraform_data.additional_subnet_geometry["api_clients"], terraform_data.additional_subnet_geometry["batch"]]
}

run "retire_detached_group_keeps_tombstone" {
  command = apply
  variables {
    additional_subnet_groups = [
      { name = "api_clients", ipv4_prefix_length = 24 },
      { name = "batch", ipv4_prefix_length = 26, retired = true },
    ]
  }
  assert {
    condition     = !contains(keys(azurerm_subnet.additional_group), "batch") && terraform_data.additional_subnet_ledger["batch"].output.retired && terraform_data.additional_subnet_geometry["batch"].output.ipv4_cidr == "10.0.97.0/26"
    error_message = "Retirement removes the detached subnet but retains its reservation and ledger."
  }
}

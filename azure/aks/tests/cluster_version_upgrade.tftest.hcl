# Applies the default cluster_version against mocks, then plans the same and the
# next minor version. check_cluster_version_upgrade.sh asserts on the JSON
# state and plans these runs produce.

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

  # azurerm validates ID/scope shapes client-side, so computed IDs consumed by
  # other resources need real shapes.
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/subnet" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip" }
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
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law" }
  }
  mock_resource "azurerm_role_assignment" {
    defaults = { condition_version = "" }
  }
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      oidc_issuer_url        = "https://oidc.example.invalid/00000000-0000-0000-0000-000000000006/"
      node_resource_group    = "MC_rg_aks_eastus"
      node_resource_group_id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/MC_rg_aks_eastus"
      id                     = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks"
      kube_config = [{
        host                   = "https://aks.example.invalid:443"
        username               = ""
        password               = ""
        client_certificate     = ""
        client_key             = ""
        cluster_ca_certificate = ""
      }]
    }
  }
  mock_resource "azurerm_kubernetes_cluster_node_pool" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks/agentPools/pool" }
  }
}

mock_provider "azapi" {}
mock_provider "local" {}
mock_provider "null" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  environment_name     = "version-test"
  location             = "eastus"
  public_root_domain   = "public.example.invalid"
  internal_root_domain = "internal.example.invalid"
  zones                = ["1"]

  aks_node_pools = {
    sandbox = {
      vm_size   = "Standard_D4als_v7"
      min_count = 0
      max_count = 2
    }
  }
}

run "apply_current_version" {
  command = apply

  assert {
    condition     = var.cluster_version == "1.34"
    error_message = "The applied baseline must use the default cluster_version."
  }
}

run "plan_same_version" {
  command = plan
}

run "plan_next_minor" {
  command = plan

  variables {
    cluster_version = "1.35"
  }
}

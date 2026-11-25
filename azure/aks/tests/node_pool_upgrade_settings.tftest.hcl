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
  environment_name     = "pool-upgrade-test"
  location             = "eastus"
  public_root_domain   = "test.example.com"
  internal_root_domain = "test.internal"
  zones                = ["1"]
}

run "omitted_settings" {
  command = plan

  variables {
    aks_node_pools = {
      application = {
        node_count = 3
        min_count  = 1
      }
      sandbox = {
        vm_size   = "Standard_D4als_v7"
        min_count = 0
        max_count = 2
      }
    }
  }

  assert {
    condition = (
      local.merged_node_pools.application.upgrade_settings == {
        max_surge                     = "33%"
        drain_timeout_in_minutes      = 30
        node_soak_duration_in_minutes = 0
      } &&
      local.merged_node_pools.sandbox.upgrade_settings == { max_surge = "33%" } &&
      local.merged_node_pools.sandbox.auto_scaling_enabled &&
      local.merged_node_pools.sandbox.min_count == 0 &&
      local.merged_node_pools.sandbox.max_count == 2 &&
      local.merged_node_pools.application.auto_scaling_enabled &&
      local.merged_node_pools.application.min_count == 1 &&
      local.merged_node_pools.application.max_count == 4
    )
    error_message = "Omitted settings must use the default upgrade settings and keep autoscaling inputs."
  }
}

run "null_settings" {
  command = plan

  variables {
    aks_node_pools = {
      system      = { upgrade_settings = null }
      application = { upgrade_settings = null }
      sandbox     = { vm_size = "Standard_D4als_v7", upgrade_settings = null }
    }
  }

  assert {
    condition = (
      local.merged_node_pools.application.upgrade_settings == {
        max_surge                     = "33%"
        drain_timeout_in_minutes      = 30
        node_soak_duration_in_minutes = 0
      } &&
      local.merged_node_pools.sandbox.upgrade_settings == { max_surge = "33%" }
    )
    error_message = "Null settings must behave exactly like omitted settings."
  }
}

run "explicit_surge" {
  command = plan

  variables {
    aks_node_pools = {
      application = {
        upgrade_settings = {
          max_surge                     = "20%"
          drain_timeout_in_minutes      = 45
          node_soak_duration_in_minutes = 10
          undrainable_node_behavior     = "Cordon"
        }
      }
      sandbox = {
        vm_size          = "Standard_D4als_v7"
        upgrade_settings = { max_surge = "10%" }
      }
    }
  }
}

run "system_behavior" {
  command = plan

  variables {
    aks_node_pools = {
      system = { upgrade_settings = { undrainable_node_behavior = "Cordon" } }
      application = {
        upgrade_settings = {
          max_surge                     = "20%"
          drain_timeout_in_minutes      = 45
          node_soak_duration_in_minutes = 10
          undrainable_node_behavior     = "Cordon"
        }
      }
    }
  }
}

run "explicit_unavailable" {
  command = plan

  variables {
    aks_node_pools = {
      application = { upgrade_settings = { max_unavailable = "1" } }
      sandbox = {
        vm_size = "Standard_D4als_v7"
        upgrade_settings = {
          max_unavailable               = "1"
          drain_timeout_in_minutes      = 60
          node_soak_duration_in_minutes = 8
          undrainable_node_behavior     = "Cordon"
        }
      }
    }
  }
}

run "reject_both_strategies" {
  command = plan

  variables {
    aks_node_pools = { application = { upgrade_settings = { max_surge = "10%", max_unavailable = "1" } } }
  }

  expect_failures = [var.aks_node_pools]
}

run "reject_no_strategy" {
  command = plan

  variables {
    aks_node_pools = { sandbox = { vm_size = "Standard_D4als_v7", upgrade_settings = {} } }
  }

  expect_failures = [var.aks_node_pools]
}

run "reject_empty_strategy" {
  command = plan

  variables {
    aks_node_pools = { application = { upgrade_settings = { max_surge = "" } } }
  }

  expect_failures = [var.aks_node_pools]
}

run "reject_system_settings" {
  command = plan

  variables {
    aks_node_pools = { system = { upgrade_settings = { max_surge = "10%" } } }
  }

  expect_failures = [var.aks_node_pools]
}

run "reject_system_empty_settings" {
  command = plan

  variables {
    aks_node_pools = { system = { upgrade_settings = {} } }
  }

  expect_failures = [var.aks_node_pools]
}

run "reject_system_surge_with_behavior" {
  command = plan

  variables {
    aks_node_pools = { system = { upgrade_settings = { max_surge = "10%", undrainable_node_behavior = "Cordon" } } }
  }

  expect_failures = [var.aks_node_pools]
}

run "reject_system_unavailable" {
  command = plan

  variables {
    aks_node_pools = { system = { upgrade_settings = { max_unavailable = "1", undrainable_node_behavior = "Cordon" } } }
  }

  expect_failures = [var.aks_node_pools]
}

run "reject_system_drain_timeout" {
  command = plan

  variables {
    aks_node_pools = { system = { upgrade_settings = { drain_timeout_in_minutes = 30, undrainable_node_behavior = "Cordon" } } }
  }

  expect_failures = [var.aks_node_pools]
}

run "reject_system_soak" {
  command = plan

  variables {
    aks_node_pools = { system = { upgrade_settings = { node_soak_duration_in_minutes = 5, undrainable_node_behavior = "Cordon" } } }
  }

  expect_failures = [var.aks_node_pools]
}

run "reject_system_unknown_behavior" {
  command = plan

  variables {
    aks_node_pools = { system = { upgrade_settings = { undrainable_node_behavior = "Drain" } } }
  }

  expect_failures = [var.aks_node_pools]
}

# Applies a system-pool behavior against mocks, then plans the same input.
run "apply_system_behavior" {
  command = apply

  variables {
    aks_node_pools = { system = { upgrade_settings = { undrainable_node_behavior = "Cordon" } } }
  }
}

run "plan_same_system_behavior" {
  command = plan

  variables {
    aks_node_pools = { system = { upgrade_settings = { undrainable_node_behavior = "Cordon" } } }
  }
}

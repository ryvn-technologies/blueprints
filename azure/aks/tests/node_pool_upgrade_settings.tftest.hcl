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
      try(local.merged_node_pools.sandbox.upgrade_settings, null) == null &&
      local.merged_node_pools.application.upgrade_settings.max_surge == "10%" &&
      local.merged_node_pools.application.upgrade_settings.drain_timeout_in_minutes == 30 &&
      local.merged_node_pools.application.upgrade_settings.node_soak_duration_in_minutes == 5 &&
      local.merged_node_pools.sandbox.auto_scaling_enabled &&
      local.merged_node_pools.sandbox.min_count == 0 &&
      local.merged_node_pools.sandbox.max_count == 2 &&
      local.merged_node_pools.application.node_count == 3 &&
      local.merged_node_pools.application.auto_scaling_enabled &&
      local.merged_node_pools.application.min_count == 1 &&
      local.merged_node_pools.application.max_count == 4
    )
    error_message = "Omitted settings must preserve application defaults, custom-pool absence, and autoscaling inputs."
  }
}

run "null_settings" {
  command = plan

  variables {
    aks_node_pools = {
      application = { upgrade_settings = null }
      sandbox     = { vm_size = "Standard_D4als_v7", upgrade_settings = null }
    }
  }

  assert {
    condition = (
      local.merged_node_pools.application.upgrade_settings.max_surge == "10%" &&
      local.merged_node_pools.application.upgrade_settings.drain_timeout_in_minutes == 30 &&
      local.merged_node_pools.application.upgrade_settings.node_soak_duration_in_minutes == 5 &&
      try(local.merged_node_pools.sandbox.upgrade_settings, null) == null
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

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
  environment_name     = "maintenance-test"
  location             = "eastus"
  public_root_domain   = "test.example.com"
  internal_root_domain = "test.internal"
  zones                = ["1"]
}

run "default_maintenance_windows_plan" {
  command = plan
}

run "maintenance_windows_can_be_disabled" {
  command = plan

  variables {
    node_os_channel_upgrade         = null
    maintenance_window_node_os      = null
    maintenance_window_auto_upgrade = null
  }
}

run "custom_daily_node_os_window_plans" {
  command = plan

  variables {
    maintenance_window_node_os = {
      frequency  = "Daily"
      interval   = 1
      duration   = 6
      start_time = "22:00"
      utc_offset = "-05:00"
      not_allowed = [{
        start = "2026-12-24T00:00:00Z"
        end   = "2026-12-27T00:00:00Z"
      }]
    }
  }
}

run "unsupported_node_os_channel_is_rejected" {
  command = plan

  variables {
    node_os_channel_upgrade = "Nightly"
  }

  expect_failures = [var.node_os_channel_upgrade]
}

run "node_os_window_shorter_than_four_hours_is_rejected" {
  command = plan

  variables {
    maintenance_window_node_os = {
      frequency   = "Weekly"
      interval    = 1
      duration    = 2
      day_of_week = "Sunday"
    }
  }

  expect_failures = [var.maintenance_window_node_os]
}

run "daily_auto_upgrade_window_is_rejected" {
  command = plan

  variables {
    maintenance_window_auto_upgrade = {
      frequency = "Daily"
      interval  = 1
      duration  = 4
    }
  }

  expect_failures = [var.maintenance_window_auto_upgrade]
}

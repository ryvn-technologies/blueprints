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
  environment_name     = "managed-cilium-test"
  location             = "eastus"
  public_root_domain   = "test.example.com"
  internal_root_domain = "test.internal"
  zones                = ["1"]
}

run "legacy_networking_is_the_default" {
  command = plan

  assert {
    condition = (
      module.aks.network_profile[0].network_data_plane == null &&
      module.aks.network_profile[0].network_policy == "azure" &&
      length(module.aks.network_profile[0].advanced_networking) == 0
    )
    error_message = "The default must preserve legacy networking without enabling ACNS."
  }
}

run "managed_cilium_configures_data_plane_and_policy" {
  command = plan

  variables {
    ebpf_data_plane = "cilium"
  }

  assert {
    condition = (
      module.aks.network_profile[0].network_data_plane == "cilium" &&
      module.aks.network_profile[0].network_policy == "cilium"
    )
    error_message = "Managed Cilium must configure both the AKS data plane and network policy engine."
  }

  assert {
    condition     = try(module.aks.network_profile[0].advanced_networking[0].security_enabled, false)
    error_message = "Managed Cilium must enable ACNS security for FQDN filtering."
  }

  assert {
    condition     = try(module.aks.network_profile[0].advanced_networking[0].observability_enabled, false)
    error_message = "Managed Cilium must enable ACNS observability for Hubble network metrics."
  }
}

run "managed_cilium_accepts_linux_pool_with_default_os_sku" {
  command = plan

  variables {
    ebpf_data_plane = "cilium"
    aks_node_pools = {
      application = {}
    }
  }

  assert {
    condition     = module.aks.network_profile[0].network_data_plane == "cilium"
    error_message = "Managed Cilium must accept Linux node pools that use the default OS SKU."
  }
}

run "managed_cilium_rejects_flat_networking" {
  command = plan

  variables {
    ebpf_data_plane     = "cilium"
    network_plugin_mode = "flat"
  }

  expect_failures = [var.ebpf_data_plane]
}

run "managed_cilium_rejects_windows_pools" {
  command = plan

  variables {
    ebpf_data_plane = "cilium"
    aks_node_pools = {
      windows = {
        vm_size    = "Standard_D2as_v6"
        min_count  = 1
        max_count  = 1
        node_count = 1
        os_sku     = "Windows2022"
      }
    }
  }

  expect_failures = [var.ebpf_data_plane]
}

run "legacy_networking_accepts_flat_mode" {
  command = plan

  variables {
    ebpf_data_plane     = null
    network_plugin_mode = "flat"
  }

  assert {
    condition = (
      module.aks.network_profile[0].network_data_plane == null &&
      module.aks.network_profile[0].network_policy == "azure" &&
      module.aks.network_profile[0].network_plugin_mode == null &&
      length(module.aks.network_profile[0].advanced_networking) == 0
    )
    error_message = "Flat networking must remain supported when Cilium is disabled."
  }
}

run "unsupported_data_plane_is_rejected" {
  command = plan

  variables {
    ebpf_data_plane = "calico"
  }

  expect_failures = [var.ebpf_data_plane]
}

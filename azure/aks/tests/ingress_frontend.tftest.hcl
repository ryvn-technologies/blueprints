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
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003", subscription_id = "00000000-0000-0000-0000-000000000003" }
  }
}
mock_provider "azapi" {}
mock_provider "local" {}
mock_provider "null" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  environment_name         = "ingress-test"
  location                 = "centralus"
  public_root_domain       = "test.example.com"
  internal_root_domain     = "test.internal"
  zones                    = ["1"]
  vnet_cidr                = "10.12.0.0/16"
  additional_subnet_groups = [{ name = "workers", ipv4_prefix_length = 24 }]
}

run "disabled_baseline" {
  command = plan
  assert {
    condition     = length(azurerm_subnet.ingress_frontend) == 0 && output.application_gateway_network.backend == null && !output.application_gateway_network.enabled && output.application_gateway_network.gateway == null
    error_message = "Opt-out must not allocate a frontend subnet or IP."
  }
}

run "enabled_preserves_every_existing_allocation" {
  command = plan
  variables { application_gateway_enabled = true }
  assert {
    condition     = { for name, subnet in output.vnet.node_pool_subnets : name => subnet.cidr } == { for name, subnet in run.disabled_baseline.vnet.node_pool_subnets : name => subnet.cidr } && { for name, subnet in output.vnet.infrastructure_subnets : name => subnet.cidr } == { for name, subnet in run.disabled_baseline.vnet.infrastructure_subnets : name => subnet.cidr } && keys(azurerm_subnet.main) == ["appgw-subnet", "private-1", "private-2", "private-3", "privatelink-subnet"]
    error_message = "Existing node/infrastructure CIDRs and resource keys must not shift."
  }
  assert {
    condition     = output.application_gateway_network.backend.subnet_cidr == "10.12.133.0/24" && output.application_gateway_network.backend.private_ip == "10.12.133.4" && azurerm_subnet.ingress_frontend[0].default_outbound_access_enabled == false
    error_message = "The frontend must use fixed slot 5 and usable host 4, without implicit outbound."
  }
  assert {
    condition     = output.application_gateway_network.enabled && output.application_gateway_network.gateway.backend_ip == output.application_gateway_network.backend.private_ip && !contains(keys(output.application_gateway_network.gateway), "public_dns_published") && !contains(keys(output.application_gateway_network.gateway), "public_dns_record_names") && length(module.egress_firewall) == 0
    error_message = "AppGW must be configured in platform state before Helm readiness, independently of Firewall and DNS publication."
  }
  assert {
    condition     = output.vnet.subnet_names == run.disabled_baseline.vnet.subnet_names && output.additional_subnet_groups["workers"].ipv4_cidr == run.disabled_baseline.additional_subnet_groups["workers"].ipv4_cidr && local.service_subnet_pool_cidr == "10.12.130.0/24" && local.postgres_subnet_cidr == "10.12.131.0/24"
    error_message = "Enabling ingress must preserve existing VNet/subnet outputs, service pool, Postgres and additional groups."
  }
}

run "flat_uses_same_fixed_infrastructure_geometry" {
  command = plan
  variables {
    application_gateway_enabled = true
    network_plugin_mode         = "flat"
  }
  assert {
    condition     = tolist(local.node_pool_subnet_cidrs) == tolist(["10.12.0.0/21", "10.12.8.0/21", "10.12.16.0/21"]) && output.application_gateway_network.backend.private_ip == "10.12.133.4"
    error_message = "Flat mode must keep its node geometry and the same dedicated frontend slot."
  }
}

run "standard_supported_size" {
  command = plan
  variables {
    application_gateway_enabled = true
    vnet_cidr                   = "10.12.0.0/19"
  }
  assert {
    condition     = output.application_gateway_network.backend.subnet_cidr == "10.12.21.0/24" && output.application_gateway_network.backend.private_ip == "10.12.21.4"
    error_message = "A supported /19 uses the existing slot geometry."
  }
}

run "reject_compact_before_invalid_slot_evaluation" {
  command = plan
  variables {
    application_gateway_enabled = true
    vnet_cidr                   = "10.12.0.0/23"
    additional_subnet_groups    = []
  }
  expect_failures = [var.application_gateway_enabled]
}

run "reject_insufficient_appgw_capacity" {
  command = plan
  variables {
    application_gateway_enabled = true
    vnet_cidr                   = "10.12.0.0/20"
  }
  expect_failures = [var.application_gateway_enabled]
}

mock_provider "azurerm" {
  mock_resource "azurerm_managed_redis" {
    defaults = {
      id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/cache-test/providers/Microsoft.Cache/redisEnterprise/cache-test"
      hostname = "cache-test.eastus.redis.azure.net"
      default_database = {
        port               = 10000
        primary_access_key = "primary+key/123"
      }
    }
  }
}
mock_provider "random" {
  mock_resource "random_id" {
    defaults = { hex = "0a1b2c3d" }
  }
}

variables {
  installation_name   = "cache"
  environment         = "test"
  resource_group_name = "cache-test"
}

run "cloud_metrics_output_emits_the_contract" {
  command = apply
  assert {
    condition     = output.cloud_metrics.schema == 1
    error_message = "cloud_metrics must carry schema 1."
  }
  assert {
    condition     = output.cloud_metrics.targets["cluster"].cloud_resource_id == "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/cache-test/providers/Microsoft.Cache/redisEnterprise/cache-test"
    error_message = "Targets must name the real Microsoft.Cache/redisEnterprise cluster ARM id."
  }
  assert {
    condition     = length(keys(output.cloud_metrics.targets)) == 1 && !can(output.cloud_metrics.targets["cluster"].enabled)
    error_message = "The declaration is resource-only — no collector enablement keys on the target."
  }
}

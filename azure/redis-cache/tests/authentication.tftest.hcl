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

run "access_keys_are_the_default" {
  command = apply
  assert {
    condition     = azurerm_managed_redis.this.default_database[0].access_keys_authentication_enabled && length(azurerm_managed_redis_access_policy_assignment.this) == 0
    error_message = "Existing callers must keep access-key authentication without creating Entra assignments."
  }
  assert {
    condition     = output.primary_access_key == "primary+key/123" && output.auth_token == "primary+key/123" && output.connection_url == "rediss://:primary%2Bkey%2F123@cache-test.eastus.redis.azure.net:10000"
    error_message = "Access-key outputs and URL encoding must remain compatible."
  }
  assert {
    condition     = output.access_keys_authentication_enabled && length(output.entra_principals) == 0
    error_message = "Key-only callers must not receive Entra principal metadata."
  }
}

run "entra_principals_can_coexist_with_access_keys" {
  command = apply
  variables {
    entra_principals = {
      api     = { object_id = "33333333-3333-3333-3333-333333333333" }
      reports = { object_id = "44444444-4444-4444-4444-444444444444" }
    }
  }
  assert {
    condition     = azurerm_managed_redis.this.default_database[0].access_keys_authentication_enabled && output.primary_access_key == "primary+key/123"
    error_message = "Adding Entra principals must not disable access keys on its own."
  }
  assert {
    condition     = length(azurerm_managed_redis_access_policy_assignment.this) == 2 && alltrue([for assignment in azurerm_managed_redis_access_policy_assignment.this : assignment.managed_redis_id == azurerm_managed_redis.this.id])
    error_message = "Each principal must receive an access policy assignment on the cache."
  }
  assert {
    condition     = output.entra_principals.api.object_id == "33333333-3333-3333-3333-333333333333" && output.entra_principals.reports.object_id == "44444444-4444-4444-4444-444444444444" && output.entra_token_scope == "https://redis.azure.com/.default"
    error_message = "Callers need each principal's object ID (the Redis username) and the token scope."
  }
}

run "entra_only_suppresses_access_keys" {
  command = apply
  variables {
    access_keys_authentication_enabled = false
    entra_principals = {
      api = { object_id = "33333333-3333-3333-3333-333333333333" }
    }
  }
  assert {
    condition     = !azurerm_managed_redis.this.default_database[0].access_keys_authentication_enabled && !output.access_keys_authentication_enabled
    error_message = "Access-key authentication must be disabled on the database."
  }
  assert {
    condition     = output.primary_access_key == null && output.auth_token == null && output.connection_url == "rediss://cache-test.eastus.redis.azure.net:10000"
    error_message = "Passwordless caches must not expose access keys or credential-bearing URLs."
  }
  assert {
    condition     = length(output.entra_principals) == 1
    error_message = "The Entra principal must remain the only login."
  }
}

run "disabling_access_keys_requires_a_principal" {
  command = plan
  variables {
    access_keys_authentication_enabled = false
  }
  expect_failures = [azurerm_managed_redis.this]
}

run "entra_principal_object_ids_must_be_guids" {
  command = plan
  variables {
    entra_principals = {
      api = { object_id = "not-a-guid" }
    }
  }
  expect_failures = [var.entra_principals]
}

run "entra_principal_object_ids_must_be_distinct" {
  command = plan
  variables {
    entra_principals = {
      api     = { object_id = "33333333-3333-3333-3333-333333333333" }
      reports = { object_id = "33333333-3333-3333-3333-333333333333" }
    }
  }
  expect_failures = [azurerm_managed_redis_access_policy_assignment.this]
}

run "entra_principal_object_ids_are_compared_case_insensitively" {
  command = plan
  variables {
    entra_principals = {
      api     = { object_id = "aaaaaaaa-3333-3333-3333-333333333333" }
      reports = { object_id = "AAAAAAAA-3333-3333-3333-333333333333" }
    }
  }
  expect_failures = [azurerm_managed_redis_access_policy_assignment.this]
}

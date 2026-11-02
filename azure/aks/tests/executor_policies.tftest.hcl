mock_provider "azurerm" {
  mock_resource "azurerm_role_assignment" {
    defaults = { condition_version = "" }
  }
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/executor-test" }
  }
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

override_resource {
  target = azurerm_user_assigned_identity.ryvn_agent
  values = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/executor-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/agent"
    principal_id = "00000000-0000-0000-0000-000000000005"
    client_id    = "00000000-0000-0000-0000-000000000006"
    tenant_id    = "00000000-0000-0000-0000-000000000004"
  }
}

variables {
  environment_name     = "executor-test"
  location             = "eastus"
  public_root_domain   = "public.example.invalid"
  internal_root_domain = "internal.example.invalid"
  zones                = ["1"]
}

run "defaults_preserve_existing_grants" {
  command = plan

  assert {
    condition     = length(azurerm_role_definition.agent) == 1 && length(azurerm_role_assignment.role_assignment) == 1 && length(azurerm_role_assignment.executor) == 0
    error_message = "Defaults must retain exactly the original agent grant."
  }

  assert {
    condition     = azurerm_role_definition.agent[0].name == "ryvn-agent-role-executor-test" && azurerm_role_definition.agent[0].scope == data.azurerm_subscription.main.id && azurerm_role_definition.agent[0].assignable_scopes == tolist([data.azurerm_subscription.main.id])
    error_message = "Default role identity and availability must remain unchanged."
  }

  assert {
    condition     = azurerm_role_definition.agent[0].permissions[0].actions == tolist(["*"]) && length(azurerm_role_definition.agent[0].permissions[0].not_actions) == 0 && try(length(azurerm_role_definition.agent[0].permissions[0].data_actions), 0) == 0 && try(length(azurerm_role_definition.agent[0].permissions[0].not_data_actions), 0) == 0
    error_message = "Default permissions must remain wildcard management actions with no data actions."
  }

  assert {
    condition     = azurerm_role_assignment.role_assignment[0].scope == data.azurerm_subscription.main.id && azurerm_role_assignment.role_assignment[0].role_definition_name == azurerm_role_definition.agent[0].name && azurerm_role_assignment.role_assignment[0].condition == null
    error_message = "The default assignment must retain its scope, selector and unconditional grant."
  }

  assert {
    condition     = azurerm_federated_identity_credential.ryvn_agent.subject == "system:serviceaccount:ryvn-system:ryvn-agent"
    error_message = "Federation must continue to target the existing agent service account."
  }
}

run "empty_object_preserves_defaults" {
  command = plan

  variables {
    terraform_executor_policies = {}
  }

  assert {
    condition     = length(azurerm_role_definition.agent) == 1 && azurerm_role_definition.agent[0].permissions[0].actions == tolist(["*"])
    error_message = "Empty configuration must retain defaults."
  }
}

run "null_preserves_defaults" {
  command = plan

  variables {
    terraform_executor_policies = null
  }

  assert {
    condition     = length(azurerm_role_assignment.role_assignment) == 1 && azurerm_role_definition.agent[0].permissions[0].actions == tolist(["*"])
    error_message = "Null must use the default configuration."
  }
}

run "custom_permissions_replace_defaults" {
  command = plan

  variables {
    terraform_executor_policies = {
      permissions = {
        actions          = ["Microsoft.Storage/storageAccounts/*"]
        not_actions      = ["Microsoft.Storage/storageAccounts/listKeys/action"]
        data_actions     = ["Microsoft.Storage/storageAccounts/blobServices/containers/blobs/*"]
        not_data_actions = ["Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete"]
        scope            = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/example"
        condition        = "(!(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'}))"
      }
    }
  }

  assert {
    condition     = azurerm_role_definition.agent[0].permissions[0].actions == var.terraform_executor_policies.permissions.actions && azurerm_role_definition.agent[0].permissions[0].not_actions == var.terraform_executor_policies.permissions.not_actions && azurerm_role_definition.agent[0].permissions[0].data_actions == toset(var.terraform_executor_policies.permissions.data_actions) && azurerm_role_definition.agent[0].permissions[0].not_data_actions == toset(var.terraform_executor_policies.permissions.not_data_actions)
    error_message = "All four permission lists must replace defaults exactly, without appended management permissions."
  }

  assert {
    condition     = azurerm_role_definition.agent[0].scope == data.azurerm_subscription.main.id && azurerm_role_assignment.role_assignment[0].scope == var.terraform_executor_policies.permissions.scope
    error_message = "The definition stays subscription-scoped while its grant uses the requested scope."
  }

  assert {
    condition     = azurerm_role_assignment.role_assignment[0].condition == var.terraform_executor_policies.permissions.condition && azurerm_role_assignment.role_assignment[0].condition_version == "2.0"
    error_message = "Custom grants must pass assignment conditions using version 2.0."
  }
}

run "data_only_grant" {
  command = plan

  variables {
    terraform_executor_policies = { permissions = { data_actions = ["Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read"] } }
  }

  assert {
    condition     = length(azurerm_role_definition.agent[0].permissions[0].actions) == 0 && azurerm_role_definition.agent[0].permissions[0].data_actions == toset(var.terraform_executor_policies.permissions.data_actions)
    error_message = "A data-only grant must not receive default management permissions."
  }
}

# Target only agent authorization resources so mock applies exercise revocation
# without provisioning unrelated cluster/network resources.
run "seed_default_grant" {
  command = apply

  plan_options {
    target = [azurerm_role_definition.agent, azurerm_role_assignment.role_assignment, azurerm_role_assignment.executor]
  }

  assert {
    condition     = length(azurerm_role_assignment.role_assignment) == 1 && azurerm_role_definition.agent[0].permissions[0].actions == tolist(["*"])
    error_message = "The override lifecycle must start with an applied wildcard grant."
  }
}

run "existing_roles_remove_default_role" {
  command = apply

  plan_options {
    target = [azurerm_role_definition.agent, azurerm_role_assignment.role_assignment, azurerm_role_assignment.executor]
  }

  variables {
    terraform_executor_policies = {
      role_assignments = {
        reader = { role_definition_name = "Reader" }
        storage = {
          role_definition_id = "/subscriptions/00000000-0000-0000-0000-000000000003/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000007"
          scope              = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/example"
          condition          = "(!(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'}))"
        }
      }
    }
  }

  assert {
    condition     = length(azurerm_role_definition.agent) == 0 && length(azurerm_role_assignment.role_assignment) == 0 && length(azurerm_role_assignment.executor) == 2
    error_message = "Existing-role overrides must remove every default agent grant and the module-owned role."
  }

  assert {
    condition     = azurerm_role_assignment.executor["reader"].role_definition_name == "Reader" && azurerm_role_assignment.executor["reader"].scope == data.azurerm_subscription.main.id && try(length(azurerm_role_assignment.executor["reader"].condition), 0) == 0 && try(length(azurerm_role_assignment.executor["reader"].condition_version), 0) == 0
    error_message = "Named roles must default to subscription scope without conditions."
  }

  assert {
    condition     = azurerm_role_assignment.executor["storage"].role_definition_id == var.terraform_executor_policies.role_assignments["storage"].role_definition_id && azurerm_role_assignment.executor["storage"].scope == var.terraform_executor_policies.role_assignments["storage"].scope && azurerm_role_assignment.executor["storage"].condition == var.terraform_executor_policies.role_assignments["storage"].condition && azurerm_role_assignment.executor["storage"].condition_version == "2.0"
    error_message = "Scoped role IDs and native conditions must pass through exactly."
  }

  assert {
    condition     = alltrue([for assignment in azurerm_role_assignment.executor : assignment.principal_id == output.ryvn_agent_role.principal_id && assignment.principal_type == "ServicePrincipal"])
    error_message = "Every supplied role must be assigned to the existing agent managed identity."
  }
}

run "tenant_level_role_id" {
  command = plan
  variables {
    terraform_executor_policies = {
      role_assignments = {
        reader = { role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7" }
      }
    }
  }
  assert {
    condition     = azurerm_role_assignment.executor["reader"].role_definition_id == var.terraform_executor_policies.role_assignments.reader.role_definition_id
    error_message = "Tenant-level Azure role-definition IDs must be accepted unchanged."
  }
}

run "permissions_and_roles_compose" {
  command = plan

  variables {
    terraform_executor_policies = {
      permissions      = { actions = ["Microsoft.Resources/subscriptions/resourceGroups/read"] }
      role_assignments = { storage = { role_definition_name = "Storage Blob Data Reader" } }
    }
  }

  assert {
    condition     = length(azurerm_role_definition.agent) == 1 && length(azurerm_role_assignment.executor) == 1 && azurerm_role_definition.agent[0].permissions[0].actions == var.terraform_executor_policies.permissions.actions
    error_message = "Only explicit custom permissions and explicit existing-role grants may compose."
  }
}

run "restore_default_grant_on_existing_identity" {
  command = apply

  plan_options {
    target = [azurerm_role_definition.agent, azurerm_role_assignment.role_assignment, azurerm_role_assignment.executor]
  }

  assert {
    condition     = length(azurerm_role_assignment.executor) == 0 && azurerm_role_definition.agent[0].permissions[0].actions == tolist(["*"])
    error_message = "Removing the override must remove supplied assignments and restore the broad default."
  }

  assert {
    condition     = azurerm_role_assignment.role_assignment[0].principal_id == output.ryvn_agent_role.principal_id && output.ryvn_agent_role.client_id == "00000000-0000-0000-0000-000000000006"
    error_message = "The restored grant and output must retain the existing managed identity."
  }
}

run "reject_empty_permissions" {
  command = plan
  variables {
    terraform_executor_policies = { permissions = {} }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_exclusions_without_grants" {
  command = plan
  variables {
    terraform_executor_policies = { permissions = { not_actions = ["Microsoft.Authorization/*"] } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_blank_operation" {
  command = plan
  variables {
    terraform_executor_policies = { permissions = { actions = [" "] } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_null_operation" {
  command = plan
  variables {
    terraform_executor_policies = { permissions = { actions = [null] } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_both_role_selectors" {
  command = plan
  variables {
    terraform_executor_policies = { role_assignments = { invalid = { role_definition_name = "Reader", role_definition_id = "/subscriptions/00000000-0000-0000-0000-000000000003/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000007" } } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_missing_role_selector" {
  command = plan
  variables {
    terraform_executor_policies = { role_assignments = { invalid = {} } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_blank_role_name" {
  command = plan
  variables {
    terraform_executor_policies = { role_assignments = { invalid = { role_definition_name = " " } } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_bare_role_id" {
  command = plan
  variables {
    terraform_executor_policies = { role_assignments = { invalid = { role_definition_id = "00000000-0000-0000-0000-000000000007" } } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_blank_scope" {
  command = plan
  variables {
    terraform_executor_policies = { role_assignments = { invalid = { role_definition_name = "Reader", scope = " " } } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_blank_condition" {
  command = plan
  variables {
    terraform_executor_policies = { role_assignments = { invalid = { role_definition_name = "Reader", condition = " " } } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_null_assignment" {
  command = plan
  variables {
    terraform_executor_policies = { role_assignments = { invalid = null } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_custom_scope_outside_subscription" {
  command = plan
  variables {
    terraform_executor_policies = { permissions = { actions = ["*/read"], scope = "/subscriptions/00000000-0000-0000-0000-000000000009" } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_custom_blank_condition" {
  command = plan
  variables {
    terraform_executor_policies = { permissions = { actions = ["*/read"], condition = " " } }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_assignment_another_subscription" {
  command = plan
  variables {
    terraform_executor_policies = {
      role_assignments = {
        escaped = {
          role_definition_name = "Owner"
          scope                = "/subscriptions/00000000-0000-0000-0000-000000000009"
        }
      }
    }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_assignment_another_subscription_resource" {
  command = plan
  variables {
    terraform_executor_policies = {
      role_assignments = {
        escaped = {
          role_definition_name = "Owner"
          scope                = "/subscriptions/00000000-0000-0000-0000-000000000009/resourceGroups/example"
        }
      }
    }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_assignment_management_group" {
  command = plan
  variables {
    terraform_executor_policies = {
      role_assignments = {
        escaped = {
          role_definition_name = "Owner"
          scope                = "/providers/Microsoft.Management/managementGroups/example"
        }
      }
    }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_assignment_tenant_root" {
  command = plan
  variables {
    terraform_executor_policies = {
      role_assignments = {
        escaped = {
          role_definition_name = "Owner"
          scope                = "/"
        }
      }
    }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_assignment_subscription_prefix_collision" {
  command = plan
  variables {
    terraform_executor_policies = {
      role_assignments = {
        escaped = {
          role_definition_name = "Owner"
          scope                = "/subscriptions/00000000-0000-0000-0000-000000000003-extra/resourceGroups/example"
        }
      }
    }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "explicit_subscription_and_resource_scopes" {
  command = plan
  variables {
    terraform_executor_policies = {
      role_assignments = {
        subscription = {
          role_definition_name = "Reader"
          scope                = "/subscriptions/00000000-0000-0000-0000-000000000003"
        }
        storage = {
          role_definition_name = "Storage Blob Data Reader"
          scope                = "/SUBSCRIPTIONS/00000000-0000-0000-0000-000000000003/resourceGroups/example/providers/Microsoft.Storage/storageAccounts/examplestorage"
        }
      }
    }
  }
  assert {
    condition     = azurerm_role_assignment.executor["subscription"].scope == var.terraform_executor_policies.role_assignments.subscription.scope && azurerm_role_assignment.executor["storage"].scope == var.terraform_executor_policies.role_assignments.storage.scope
    error_message = "Same-subscription scopes must remain usable, including case-insensitive ARM paths."
  }
}

run "reject_assignment_dot_segment_escape" {
  command = plan
  variables {
    terraform_executor_policies = {
      role_assignments = {
        escaped = {
          role_definition_name = "Owner"
          scope                = "/subscriptions/00000000-0000-0000-0000-000000000003/../../subscriptions/00000000-0000-0000-0000-000000000009"
        }
      }
    }
  }
  expect_failures = [var.terraform_executor_policies]
}

run "reject_assignment_encoded_dot_segment_escape" {
  command = plan
  variables {
    terraform_executor_policies = {
      role_assignments = {
        escaped = {
          role_definition_name = "Owner"
          scope                = "/subscriptions/00000000-0000-0000-0000-000000000003/%2e%2e/%2e%2e/subscriptions/00000000-0000-0000-0000-000000000009"
        }
      }
    }
  }
  expect_failures = [var.terraform_executor_policies]
}

mock_provider "azurerm" {
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = {
      id   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/postgres-test/providers/Microsoft.DBforPostgreSQL/flexibleServers/postgres-test"
      fqdn = "postgres-test.postgres.database.azure.com"
    }
  }
}
mock_provider "random" {}

variables {
  name_prefix         = "postgres"
  environment         = "test"
  resource_group_name = "postgres-test"
}

run "password_authentication_is_the_default" {
  command = apply
  variables {
    database_username = "pgadmin"
    database_password = "Test-password+123"
  }
  assert {
    condition     = !azurerm_postgresql_flexible_server.this.authentication[0].active_directory_auth_enabled && azurerm_postgresql_flexible_server.this.authentication[0].password_auth_enabled && length(azurerm_postgresql_flexible_server_active_directory_administrator.this) == 0
    error_message = "Existing callers must retain password-only authentication without creating Entra administrators."
  }
  assert {
    condition     = output.username == "pgadmin" && output.password == var.database_password && output.connection_string == "postgresql://pgadmin:Test-password%2B123@postgres-test.postgres.database.azure.com:5432/postgres?sslmode=require"
    error_message = "Existing password outputs and URL encoding must remain compatible."
  }
  assert {
    condition     = output.entra_tenant_id == null && length(output.entra_administrators) == 0
    error_message = "Password-only callers must not receive Entra connection metadata."
  }
}

run "mixed_authentication_preserves_passwords_and_encryption_identity" {
  command = apply
  variables {
    database_username                = "pgadmin"
    database_password                = "Test-password+123"
    entra_authentication_enabled     = true
    entra_tenant_id                  = "22222222-2222-2222-2222-222222222222"
    customer_managed_key_id          = "https://postgres-test.vault.azure.net/keys/postgres"
    customer_managed_key_identity_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/postgres-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/encryption"
    entra_administrators = {
      bootstrap = {
        object_id      = "33333333-3333-3333-3333-333333333333"
        principal_name = "postgres-bootstrap"
        principal_type = "ServicePrincipal"
      }
      operators = {
        object_id      = "44444444-4444-4444-4444-444444444444"
        principal_name = "Database Operators"
        principal_type = "Group"
      }
    }
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this.authentication[0].active_directory_auth_enabled && azurerm_postgresql_flexible_server.this.authentication[0].password_auth_enabled && output.password == var.database_password && output.connection_string != null && length(output.entra_administrators) == 2
    error_message = "Mixed authentication must preserve existing password access and provision all configured administrators."
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this.identity[0].identity_ids == toset([var.customer_managed_key_identity_id]) && output.entra_administrators["operators"].principal_type == "Group"
    error_message = "Entra administrators must remain independent of the server's encryption identity."
  }
}

run "rejects_disabling_both_authentication_methods" {
  command = plan
  variables {
    password_authentication_enabled = false
  }
  expect_failures = [var.password_authentication_enabled]
}

run "password_authentication_requires_a_username" {
  command = plan
  variables {
    database_password = "Test-password+123"
  }
  expect_failures = [var.database_username]
}

run "password_authentication_requires_a_password" {
  command = plan
  variables {
    database_username = "pgadmin"
  }
  expect_failures = [var.database_password]
}

run "entra_requires_a_tenant" {
  command = plan
  variables {
    entra_authentication_enabled    = true
    password_authentication_enabled = false
    entra_administrators = {
      bootstrap = {
        object_id      = "33333333-3333-3333-3333-333333333333"
        principal_name = "postgres-bootstrap"
        principal_type = "ServicePrincipal"
      }
    }
  }
  expect_failures = [var.entra_tenant_id]
}

run "entra_requires_an_administrator" {
  command = plan
  variables {
    entra_authentication_enabled    = true
    password_authentication_enabled = false
    entra_tenant_id                 = "22222222-2222-2222-2222-222222222222"
  }
  expect_failures = [var.entra_administrators]
}

run "rejects_administrators_when_entra_is_disabled" {
  command = plan
  variables {
    database_username = "pgadmin"
    database_password = "Test-password+123"
    entra_administrators = {
      bootstrap = {
        object_id      = "33333333-3333-3333-3333-333333333333"
        principal_name = "postgres-bootstrap"
        principal_type = "ServicePrincipal"
      }
    }
  }
  expect_failures = [var.entra_administrators]
}

run "rejects_duplicate_administrator_identities" {
  command = plan
  variables {
    entra_authentication_enabled    = true
    password_authentication_enabled = false
    entra_tenant_id                 = "22222222-2222-2222-2222-222222222222"
    entra_administrators = {
      first = {
        object_id      = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        principal_name = "postgres-bootstrap"
        principal_type = "ServicePrincipal"
      }
      second = {
        object_id      = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        principal_name = "postgres-bootstrap"
        principal_type = "ServicePrincipal"
      }
    }
  }
  expect_failures = [var.entra_administrators]
}

run "managed_identities_require_the_service_principal_type" {
  command = plan
  variables {
    entra_authentication_enabled    = true
    password_authentication_enabled = false
    entra_tenant_id                 = "22222222-2222-2222-2222-222222222222"
    entra_administrators = {
      bootstrap = {
        object_id      = "33333333-3333-3333-3333-333333333333"
        principal_name = "postgres-bootstrap"
        principal_type = "ManagedIdentity"
      }
    }
  }
  expect_failures = [var.entra_administrators]
}

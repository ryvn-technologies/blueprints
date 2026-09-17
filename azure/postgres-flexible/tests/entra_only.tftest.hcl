mock_provider "azurerm" {
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/postgres-test/providers/Microsoft.DBforPostgreSQL/flexibleServers/postgres-test"
    }
  }
}
mock_provider "random" {}

variables {
  name_prefix         = "postgres"
  environment         = "test"
  resource_group_name = "postgres-test"
}

# Separate test state ensures this provisions a new server without local credentials.
run "entra_only_bootstraps_a_caller_owned_identity_without_passwords" {
  command = apply
  variables {
    entra_authentication_enabled    = true
    password_authentication_enabled = false
    entra_tenant_id                 = "22222222-2222-2222-2222-222222222222"
    database_name                   = "appdb"
    entra_administrators = {
      bootstrap = {
        object_id      = "33333333-3333-3333-3333-333333333333"
        principal_name = "postgres-bootstrap"
        principal_type = "ServicePrincipal"
      }
    }
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this.authentication[0].active_directory_auth_enabled && !azurerm_postgresql_flexible_server.this.authentication[0].password_auth_enabled && azurerm_postgresql_flexible_server.this.authentication[0].tenant_id == var.entra_tenant_id && azurerm_postgresql_flexible_server.this.administrator_password == null
    error_message = "Entra-only servers must trust the selected tenant without configuring a local password."
  }
  assert {
    condition     = output.username == null && output.password == null && output.connection_string == null
    error_message = "Entra-only servers must not expose password-based credentials or connection strings."
  }
  assert {
    condition     = azurerm_postgresql_flexible_server_active_directory_administrator.this["bootstrap"].object_id == var.entra_administrators.bootstrap.object_id && azurerm_postgresql_flexible_server_active_directory_administrator.this["bootstrap"].server_name == azurerm_postgresql_flexible_server.this.name && azurerm_postgresql_flexible_server_active_directory_administrator.this["bootstrap"].tenant_id == var.entra_tenant_id
    error_message = "The caller's identity must be registered as administrator on this server in the configured tenant."
  }
  assert {
    condition     = output.entra_tenant_id == var.entra_tenant_id && output.entra_administrators["bootstrap"].principal_name == "postgres-bootstrap" && output.entra_administrators["bootstrap"].principal_type == "ServicePrincipal" && output.entra_administrators["bootstrap"].object_id == var.entra_administrators.bootstrap.object_id
    error_message = "Bootstrap consumers need the provisioned administrator's login name and identity metadata."
  }
  assert {
    condition     = length(azurerm_postgresql_flexible_server.this.identity) == 0 && output.database_name == "appdb"
    error_message = "Workload authentication must work without attaching an identity to the database server."
  }
}


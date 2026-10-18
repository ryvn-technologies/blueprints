mock_provider "azurerm" {
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = {
      id   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/postgres-test/providers/Microsoft.DBforPostgreSQL/flexibleServers/postgres-0a1b2c3d"
      fqdn = "postgres-0a1b2c3d.postgres.database.azure.com"
    }
  }
}
mock_provider "random" {
  mock_resource "random_id" {
    defaults = { hex = "0a1b2c3d" }
  }
}

variables {
  name_prefix         = "postgres"
  environment         = "test"
  resource_group_name = "postgres-test"
  database_username   = "pgadmin"
  database_password   = "bootstrap-password"
}

run "cloud_metrics_output_emits_the_contract" {
  command = apply

  assert {
    condition     = output.cloud_metrics.schema == 1 && toset(keys(output.cloud_metrics)) == toset(["schema", "targets"])
    error_message = "cloud_metrics must carry schema 1 and resource targets only."
  }
  assert {
    condition     = toset(keys(output.cloud_metrics.targets)) == toset(["this"]) && toset(keys(output.cloud_metrics.targets.this)) == toset(["cloud_resource_id"])
    error_message = "The server target must be resource-only; installing cloud-metrics is the separate collection opt-in."
  }
  assert {
    condition     = output.cloud_metrics.targets.this.cloud_resource_id == "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/postgres-test/providers/Microsoft.DBforPostgreSQL/flexibleServers/postgres-0a1b2c3d"
    error_message = "Azure Postgres must emit its full flexibleServers ARM ID, not the server name or hostname."
  }
}

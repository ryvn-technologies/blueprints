mock_provider "google" {
  mock_resource "google_sql_database_instance" {
    defaults = {
      id        = "projects/test-project/instances/postgres-0a1b2c3d"
      self_link = "https://sqladmin.googleapis.com/sql/v1beta4/projects/test-project/instances/postgres-0a1b2c3d"
    }
  }
}
mock_provider "random" {
  mock_resource "random_id" {
    defaults = { hex = "0a1b2c3d" }
  }
}
mock_provider "time" {}

variables {
  project_id        = "test-project"
  name_prefix       = "postgres"
  environment       = "test"
  private_network   = "projects/test-project/global/networks/default"
  database_password = "bootstrap-password"
}

run "cloud_metrics_output_emits_the_contract" {
  command = apply

  assert {
    condition     = output.cloud_metrics.schema == 1 && toset(keys(output.cloud_metrics)) == toset(["schema", "targets"])
    error_message = "cloud_metrics must carry schema 1 and resource targets only."
  }
  assert {
    condition     = toset(keys(output.cloud_metrics.targets)) == toset(["this"]) && toset(keys(output.cloud_metrics.targets.this)) == toset(["cloud_resource_id"])
    error_message = "The instance target must be resource-only; installing cloud-metrics is the separate collection opt-in."
  }
  assert {
    condition     = output.cloud_metrics.targets.this.cloud_resource_id == "projects/test-project/instances/postgres-0a1b2c3d"
    error_message = "Cloud SQL must emit the canonical projects/<project>/instances/<instance> path, not its self_link or proxy connection name."
  }
}

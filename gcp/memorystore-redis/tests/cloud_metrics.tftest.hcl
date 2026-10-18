mock_provider "google" {
  mock_resource "google_redis_instance" {
    defaults = {
      id   = "projects/test-project/locations/us-central1/instances/cache-0a1b2c3d"
      host = "10.0.0.2"
      port = 6379
    }
  }
}
mock_provider "random" {
  mock_resource "random_id" {
    defaults = { hex = "0a1b2c3d" }
  }
}

variables {
  project_id         = "test-project"
  installation_name  = "cache"
  environment        = "test"
  authorized_network = "projects/test-project/global/networks/default"
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
    condition     = output.cloud_metrics.targets.this.cloud_resource_id == "projects/test-project/locations/us-central1/instances/cache-0a1b2c3d"
    error_message = "Memorystore must emit the project- and region-qualified instance path, not the short instance name or host."
  }
}

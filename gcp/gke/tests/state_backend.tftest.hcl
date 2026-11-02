mock_provider "google" {
  mock_resource "google_compute_global_address" {
    defaults = { address = "10.21.0.0" }
  }
  mock_data "google_container_engine_versions" {
    defaults = {
      release_channel_default_version = { REGULAR = "1.36.3-gke.1640000" }
      release_channel_latest_version  = { REGULAR = "1.36.3-gke.1767000" }
    }
  }
  mock_data "google_client_openid_userinfo" {
    defaults = { email = "terraform@test-project.iam.gserviceaccount.com" }
  }
  mock_resource "google_service_account" {
    defaults = {
      name   = "projects/test-project/serviceAccounts/gke-test-sa@test-project.iam.gserviceaccount.com"
      email  = "gke-test-sa@test-project.iam.gserviceaccount.com"
      member = "serviceAccount:gke-test-sa@test-project.iam.gserviceaccount.com"
    }
  }
}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "random" {}

variables {
  environment                  = "original"
  cluster_service_account_name = "test-cluster"
  environment_id               = "12345678-1234-5678-9abc-123456789abc"
  project_id                   = "test-project"
  region                       = "us-central1"
  zones                        = ["us-central1-a"]
  public_root_domain           = "example.invalid"
  internal_root_domain         = "internal.example.invalid"
}

run "default_off" {
  command = apply
  assert {
    condition     = length(module.state_backend) == 0 && output.pulumi_backend_url == null && output.pulumi_secrets_provider == null
    error_message = "Disabled by default: no backend resources or advertised descriptor."
  }
}

run "enable_in_main_apply" {
  command = apply
  variables { managed_state_backend_enabled = true }
  assert {
    condition     = length(module.state_backend) == 1 && output.pulumi_backend_url == "gs://state-12345678-1234-5678-9abc-123456789abc/pulumi/"
    error_message = "The main GKE apply must create a UUID-named backend with a Pulumi namespace."
  }
  assert {
    condition     = output.pulumi_secrets_provider == "gcpkms://projects/test-project/locations/us-central1/keyRings/state-12345678-1234-5678-9abc-123456789abc/cryptoKeys/state-secrets"
    error_message = "Publish the stable native secrets-provider URI."
  }
}

run "rename" {
  command = plan
  variables {
    environment                   = "renamed"
    managed_state_backend_enabled = true
  }
  assert {
    condition     = output.pulumi_backend_url == run.enable_in_main_apply.pulumi_backend_url && output.pulumi_secrets_provider == run.enable_in_main_apply.pulumi_secrets_provider
    error_message = "Display-name changes must not change state authority."
  }
}

# Mocked provider deletion exercises Terraform's graph, not actual cloud retention.
run "disable_in_main_apply" {
  command = apply
  variables { managed_state_backend_enabled = false }
  assert {
    condition     = length(module.state_backend) == 0 && output.pulumi_backend_url == null && output.pulumi_secrets_provider == null
    error_message = "Disabling must succeed and stop advertising the abandoned backend."
  }
}

# Leave the backend enabled so the suite's final cleanup also destroys the
# environment graph. Mocks do not simulate name conflicts after abandonment.
run "enabled_before_cleanup_destroy" {
  command = apply
  variables { managed_state_backend_enabled = true }
  assert {
    condition     = output.pulumi_backend_url == run.enable_in_main_apply.pulumi_backend_url
    error_message = "Re-enabling must continue to use the same stable identity."
  }
}

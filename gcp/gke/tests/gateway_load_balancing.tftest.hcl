mock_provider "google" {
  mock_data "google_client_openid_userinfo" {
    defaults = {
      email = "terraform@example.iam.gserviceaccount.com"
    }
  }

  mock_data "google_container_engine_versions" {
    defaults = {
      latest_master_version = "1.37.0-gke.1000000"
      release_channel_default_version = {
        REGULAR = "1.35.7-gke.1222000"
      }
      release_channel_latest_version = {
        REGULAR = "1.36.3-gke.1767000"
        RAPID   = "1.37.0-gke.1000000"
      }
    }
  }
}

mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "random" {}

variables {
  environment          = "test"
  project_id           = "test-project"
  region               = "us-central1"
  zones                = ["us-central1-a"]
  public_root_domain   = "test.example.com"
  internal_root_domain = "test.internal"
}

run "older_default_uses_latest_regular_version" {
  command = plan

  assert {
    condition     = module.gke.min_master_version == "1.36.3-gke.1767000"
    error_message = "An older default must select the latest available Regular version, without using Rapid."
  }

  assert {
    condition     = module.gke.release_channel == "REGULAR"
    error_message = "Version selection must retain Regular-channel automatic upgrades."
  }

  assert {
    condition     = !module.gke.http_load_balancing_enabled
    error_message = "The HTTP load balancing add-on must stay disabled."
  }
}

run "default_at_floor_leaves_version_selection_to_gke" {
  command = plan

  override_data {
    target = data.google_container_engine_versions.gke
    values = {
      release_channel_default_version = {
        REGULAR = "1.36.3-gke.1640000"
      }
      release_channel_latest_version = {
        REGULAR = "1.36.3-gke.1767000"
      }
    }
  }

  assert {
    condition     = module.gke.min_master_version == null
    error_message = "Once the Regular default meets the floor, GKE must control version selection and upgrades."
  }
}

run "new_clusters_work_after_1_36_is_retired" {
  command = plan

  override_data {
    target = data.google_container_engine_versions.gke
    values = {
      valid_master_versions = ["1.38.0-gke.1000000", "1.37.4-gke.1000000"]
      release_channel_default_version = {
        REGULAR = "1.37.4-gke.1000000"
      }
      release_channel_latest_version = {
        REGULAR = "1.38.0-gke.1000000"
      }
    }
  }

  assert {
    condition     = module.gke.min_master_version == null
    error_message = "New clusters must follow the newer Regular default after 1.36 is no longer available."
  }
}

mock_provider "google" {
  mock_resource "google_compute_global_address" {
    defaults = {
      address = "10.21.0.0"
    }
  }
  mock_data "google_client_openid_userinfo" {
    defaults = {
      email = "terraform@example.iam.gserviceaccount.com"
    }
  }

  mock_data "google_container_engine_versions" {
    defaults = {
      release_channel_default_version = {
        REGULAR = "1.36.3-gke.1640000"
      }
      release_channel_latest_version = {
        REGULAR = "1.36.3-gke.1767000"
      }
    }
  }

  # Mocked strings fail the provider's IAM member validation on apply.
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
  environment          = "test"
  project_id           = "test-project"
  region               = "us-central1"
  zones                = ["us-central1-a"]
  public_root_domain   = "test.example.com"
  internal_root_domain = "test.internal"
}

run "location_policy_unset_by_default" {
  command = plan

  assert {
    condition     = try(local.node_pools["application"].location_policy, null) == null
    error_message = "Pools without location_policy should leave it to the GKE default."
  }
}

run "location_policy_passes_through" {
  command = plan

  variables {
    node_pools = {
      batch = {
        machine_type    = "n2-highmem-32"
        total_min_count = 0
        total_max_count = 3
        location_policy = "ANY"
      }
    }
  }

  assert {
    condition     = one([for pool in local.gke_node_pools : pool.location_policy if pool.name == "batch"]) == "ANY"
    error_message = "location_policy should be passed to the GKE module node pool."
  }
}

run "location_policy_rejects_unknown_value" {
  command = plan

  variables {
    node_pools = {
      batch = {
        location_policy = "ZONAL"
      }
    }
  }

  expect_failures = [var.node_pools]
}

run "location_policy_rejects_empty_string" {
  command = plan

  variables {
    node_pools = {
      batch = {
        location_policy = ""
      }
    }
  }

  expect_failures = [var.node_pools]
}

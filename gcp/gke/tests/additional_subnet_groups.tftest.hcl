# Stateful allocation guard: runs share state, so each one plans against the
# records the previous apply wrote.

mock_provider "google" {
  mock_data "google_client_openid_userinfo" {
    defaults = {
      email = "terraform@example.iam.gserviceaccount.com"
    }
  }

  mock_data "google_container_engine_versions" {
    defaults = {
      release_channel_default_version = { REGULAR = "1.36.3-gke.1640000" }
      release_channel_latest_version  = { REGULAR = "1.36.3-gke.1767000" }
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      email  = "ryvn-mock@test-project.iam.gserviceaccount.com"
      member = "serviceAccount:ryvn-mock@test-project.iam.gserviceaccount.com"
      name   = "projects/test-project/serviceAccounts/ryvn-mock@test-project.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_compute_global_address" {
    defaults = {
      address = "10.21.0.0"
    }
  }
}

mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "random" {}

override_module {
  target = module.gke
  outputs = {
    name                        = "ryvn-gke-ag"
    location                    = "us-central1"
    endpoint                    = "10.0.0.2"
    endpoint_dns                = "gke-ag.us-central1.gke.goog"
    ca_certificate              = "Y2E="
    service_account             = "nodes@test-project.iam.gserviceaccount.com"
    min_master_version          = null
    release_channel             = "REGULAR"
    http_load_balancing_enabled = false
  }
}

variables {
  environment           = "ag"
  project_id            = "test-project"
  region                = "us-central1"
  zones                 = ["us-central1-a"]
  public_root_domain    = "test.example.com"
  internal_root_domain  = "test.internal"
  skip_dns_provisioning = true

  additional_subnet_groups = [
    { name = "api_clients", ipv4_prefix_length = 24 },
    { name = "batch", ipv4_prefix_length = 26 },
  ]
}

run "first_apply_records_allocations" {
  assert {
    condition     = google_compute_subnetwork.additional_group["api_clients"].ip_cidr_range == "10.0.192.0/24" && google_compute_subnetwork.additional_group["batch"].ip_cidr_range == "10.0.193.0/26"
    error_message = "Subnets must use the recorded allocation."
  }
}

run "append_keeps_existing_allocations" {
  variables {
    additional_subnet_groups = [
      { name = "api_clients", ipv4_prefix_length = 24 },
      { name = "batch", ipv4_prefix_length = 26 },
      { name = "jobs", ipv4_prefix_length = 24 },
    ]
  }

  assert {
    condition     = google_compute_subnetwork.additional_group["api_clients"].ip_cidr_range == "10.0.192.0/24" && google_compute_subnetwork.additional_group["jobs"].ip_cidr_range == "10.0.194.0/24"
    error_message = "Appending a group must not move existing allocations."
  }
}

run "reorder_is_rejected" {
  command = plan

  variables {
    additional_subnet_groups = [
      { name = "batch", ipv4_prefix_length = 26 },
      { name = "api_clients", ipv4_prefix_length = 24 },
      { name = "jobs", ipv4_prefix_length = 24 },
    ]
  }

  expect_failures = [terraform_data.additional_subnet_geometry]
}

run "resize_is_rejected" {
  command = plan

  variables {
    additional_subnet_groups = [
      { name = "api_clients", ipv4_prefix_length = 23 },
      { name = "batch", ipv4_prefix_length = 26 },
      { name = "jobs", ipv4_prefix_length = 24 },
    ]
  }

  expect_failures = [terraform_data.additional_subnet_geometry]
}

run "moving_the_allocation_range_is_rejected" {
  command = plan

  variables {
    additional_subnet_groups_cidr = "10.0.160.0/19"
    additional_subnet_groups = [
      { name = "api_clients", ipv4_prefix_length = 24 },
      { name = "batch", ipv4_prefix_length = 26 },
      { name = "jobs", ipv4_prefix_length = 24 },
    ]
  }

  expect_failures = [terraform_data.additional_subnet_geometry]
}

run "retiring_removes_the_subnet_but_keeps_the_range" {
  variables {
    additional_subnet_groups = [
      { name = "api_clients", ipv4_prefix_length = 24 },
      { name = "batch", ipv4_prefix_length = 26, retired = true },
      { name = "jobs", ipv4_prefix_length = 24 },
    ]
  }

  assert {
    condition     = !contains(keys(google_compute_subnetwork.additional_group), "batch") && google_compute_subnetwork.additional_group["jobs"].ip_cidr_range == "10.0.194.0/24"
    error_message = "A retired group loses its subnet while later allocations stay in place."
  }

  assert {
    condition     = terraform_data.additional_subnet_geometry["batch"].output.ipv4_cidr == "10.0.193.0/26"
    error_message = "A retired group's allocation record stays."
  }
}

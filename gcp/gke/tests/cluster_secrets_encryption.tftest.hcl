mock_provider "google" {
  mock_data "google_client_openid_userinfo" {
    defaults = {
      email = "terraform@example.iam.gserviceaccount.com"
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

run "ryvn_key_by_default" {
  command = plan

  assert {
    condition     = length(module.cluster_kms) == 1 && output.cluster_secrets_encryption.customer_managed_key
    error_message = "Default should create a key and use it."
  }
}

run "existing_key_skips_key_creation" {
  command = plan

  variables {
    existing_cluster_kms_key_name = "projects/security-project/locations/us-central1/keyRings/gke/cryptoKeys/secrets"
  }

  assert {
    condition     = length(module.cluster_kms) == 0 && output.cluster_secrets_encryption.key_name == var.existing_cluster_kms_key_name
    error_message = "An existing key should be used without creating one."
  }
}

run "opt_out_keeps_default_encryption_at_rest" {
  command = plan

  variables {
    create_cluster_kms_key = false
  }

  assert {
    condition     = length(module.cluster_kms) == 0 && !output.cluster_secrets_encryption.customer_managed_key && output.cluster_secrets_encryption.key_name == null
    error_message = "Opting out should create no key and set no key on the cluster."
  }
}

run "mode_is_recorded_on_first_apply" {
  command = apply

  assert {
    condition     = terraform_data.cluster_secrets_encryption_mode.output == "managed"
    error_message = "The first apply should record the managed mode."
  }
}

run "mode_cannot_change_after_provisioning" {
  command = plan

  variables {
    create_cluster_kms_key = false
  }

  expect_failures = [terraform_data.cluster_secrets_encryption_mode]
}

run "existing_key_must_be_in_the_cluster_region" {
  command = plan

  variables {
    existing_cluster_kms_key_name = "projects/security-project/locations/europe-west1/keyRings/gke/cryptoKeys/secrets"
  }

  expect_failures = [var.existing_cluster_kms_key_name]
}

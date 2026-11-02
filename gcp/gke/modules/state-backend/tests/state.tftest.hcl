mock_provider "google" {}

variables {
  project_id                  = "test-project"
  location                    = "us-central1"
  environment_id              = "12345678-1234-5678-9abc-123456789abc"
  agent_service_account_email = "agent@test-project.iam.gserviceaccount.com"
}

run "abandon_data_and_key_versions" {
  command = apply
  assert {
    condition     = google_storage_bucket.state.deletion_policy == "ABANDON" && !google_storage_bucket.state.force_destroy && google_storage_bucket.state.versioning[0].enabled
    error_message = "The bucket and its versioned contents must be abandoned, not deleted."
  }
  assert {
    condition     = google_kms_crypto_key.state.deletion_policy == "ABANDON"
    error_message = "Native ABANDON must skip key-version destruction."
  }
  assert {
    condition     = google_storage_bucket.state.name == "state-${var.environment_id}" && google_kms_key_ring.state.name == "state-${var.environment_id}"
    error_message = "Shared infrastructure names must be neutral and stable."
  }
  assert {
    condition     = google_storage_bucket_iam_member.agent_state.member == "serviceAccount:${var.agent_service_account_email}" && google_kms_crypto_key_iam_member.agent_secrets.member == "serviceAccount:${var.agent_service_account_email}"
    error_message = "Use the existing agent identity for runtime state and key access."
  }
}

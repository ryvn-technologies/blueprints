resource "google_project_service" "required" {
  for_each = toset(["storage.googleapis.com", "cloudkms.googleapis.com"])

  project                    = var.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

resource "google_storage_bucket" "state" {
  project                     = var.project_id
  name                        = "state-${var.environment_id}"
  location                    = upper(var.location)
  storage_class               = "STANDARD"
  force_destroy               = false
  deletion_policy             = "ABANDON"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  labels = {
    environment_id = var.environment_id
    purpose        = "infrastructure-state"
  }

  depends_on = [google_project_service.required]
}

# GCP key rings cannot be deleted. Terraform forgets the ring on destroy.
resource "google_kms_key_ring" "state" {
  project  = var.project_id
  location = var.location
  name     = "state-${var.environment_id}"

  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key" "state" {
  name                       = "state-secrets"
  key_ring                   = google_kms_key_ring.state.id
  purpose                    = "ENCRYPT_DECRYPT"
  rotation_period            = "7776000s"
  destroy_scheduled_duration = "2592000s"
  deletion_policy            = "ABANDON"

  labels = {
    environment_id = var.environment_id
    purpose        = "infrastructure-state"
  }
}

resource "google_storage_bucket_iam_member" "agent_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.agent_service_account_email}"
}

resource "google_kms_crypto_key_iam_member" "agent_secrets" {
  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${var.agent_service_account_email}"
}

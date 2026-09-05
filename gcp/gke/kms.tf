# Encrypts Kubernetes Secrets with a Cloud KMS key. Ryvn creates the key unless the environment
# brings its own or opts out. Turning this on for an existing cluster is an in-place update.

locals {
  create_cluster_kms_key    = var.create_cluster_kms_key && var.existing_cluster_kms_key_name == null
  cluster_secrets_encrypted = var.create_cluster_kms_key || var.existing_cluster_kms_key_name != null
  cluster_kms_key_name      = "ryvn-gke-${var.environment}-secrets"

  cluster_secrets_encryption_mode = (
    var.existing_cluster_kms_key_name != null
    ? "existing:${var.existing_cluster_kms_key_name}"
    : var.create_cluster_kms_key ? "managed" : "disabled"
  )

  # Key GKE uses, or null when opted out. Going through the IAM grant makes the cluster wait for it.
  cluster_secrets_kms_key = (
    var.existing_cluster_kms_key_name != null
    ? var.existing_cluster_kms_key_name
    : one(google_kms_crypto_key_iam_member.gke_service_agent[*].crypto_key_id)
  )
}

resource "google_project_service" "cloudkms" {
  count = local.create_cluster_kms_key ? 1 : 0

  project            = var.project_id
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

# The GKE service agent that will use the key.
resource "google_project_service_identity" "container" {
  provider = google-beta
  count    = local.create_cluster_kms_key ? 1 : 0

  project = var.project_id
  service = "container.googleapis.com"
}

# Key rings can't be deleted in GCP, so a re-provisioned environment needs a fresh ring name.
resource "random_id" "cluster_kms" {
  count = local.create_cluster_kms_key ? 1 : 0

  byte_length = 4
}

# Key in the cluster's region, rotated every 90 days. prevent_destroy is off so deprovision can
# remove it.
module "cluster_kms" {
  source  = "terraform-google-modules/kms/google"
  version = "4.1.2"
  count   = local.create_cluster_kms_key ? 1 : 0

  project_id      = var.project_id
  location        = var.region
  keyring         = "ryvn-gke-${var.environment}-${random_id.cluster_kms[0].hex}"
  keys            = [local.cluster_kms_key_name]
  prevent_destroy = false

  depends_on = [google_project_service.cloudkms]
}

# Freezes the encryption mode chosen on the first apply. Changing it later would update the cluster
# and destroy the old key in the same apply; if the GKE re-encryption fails part-way (or runs within
# hours of enabling), Secrets end up encrypted with a key that no longer exists. Support can
# deliberately change the mode with `terraform apply -replace=terraform_data.cluster_secrets_encryption_mode`.
resource "terraform_data" "cluster_secrets_encryption_mode" {
  input = local.cluster_secrets_encryption_mode

  lifecycle {
    ignore_changes = [input]

    postcondition {
      condition     = self.output == local.cluster_secrets_encryption_mode
      error_message = "Secrets encryption settings cannot be changed after the environment is provisioned. Contact Ryvn support to change them."
    }
  }
}

# Outside the module so gke.tf can depend on just the grant.
resource "google_kms_crypto_key_iam_member" "gke_service_agent" {
  count = local.create_cluster_kms_key ? 1 : 0

  crypto_key_id = module.cluster_kms[0].keys[local.cluster_kms_key_name]
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.container[0].email}"
}

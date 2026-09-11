output "bucket_name" {
  description = "Full name of the GCS bucket (including the random suffix). Pass it to the workload identity module's role_groups.<group>.buckets.<key>.name."
  value       = google_storage_bucket.this.name
}

output "bucket_id" {
  description = "Cloud-native identifier for the bucket (the self link on GCP)"
  value       = google_storage_bucket.this.self_link
}

output "bucket_domain_name" {
  description = "Domain name of the bucket (e.g. my-bucket.storage.googleapis.com)"
  value       = "${google_storage_bucket.this.name}.storage.googleapis.com"
}

output "region" {
  description = "GCP location where the bucket was created"
  value       = google_storage_bucket.this.location
}

output "endpoint" {
  description = "Cloud Storage endpoint URL"
  value       = "https://storage.googleapis.com"
}

output "iam_role" {
  description = "IAM role that grants read/write access to objects in this bucket. Pass it to the workload identity module's role_groups.<group>.buckets.<key>.role."
  value       = "roles/storage.objectUser"
}

output "workload_grants" {
  description = "Grants for the workload identity module. Each entry binds `role` on the `target` resource of the given `kind` (here the bucket, via role_groups.<group>.buckets)."
  value = [{
    kind   = "bucket"
    target = google_storage_bucket.this.name
    role   = "roles/storage.objectUser"
  }]
}

output "encryption_key_id" {
  description = "Customer-managed Cloud KMS key used for encryption, or empty when Google-managed keys are used."
  value       = var.kms_key_name
}

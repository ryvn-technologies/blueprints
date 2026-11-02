output "backend_url" {
  description = "Pulumi namespace in the shared state bucket."
  value       = "gs://${google_storage_bucket.state.name}/pulumi/"
  depends_on  = [google_storage_bucket_iam_member.agent_state]
}

output "secrets_provider" {
  value      = "gcpkms://projects/${var.project_id}/locations/${var.location}/keyRings/${google_kms_key_ring.state.name}/cryptoKeys/${google_kms_crypto_key.state.name}"
  depends_on = [google_kms_crypto_key_iam_member.agent_secrets]
}

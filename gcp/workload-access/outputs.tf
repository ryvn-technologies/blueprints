output "project_number" {
  description = "Project number used in the Workload Identity principals"
  value       = local.project_number
}

output "members" {
  description = "Workload Identity principal per granted ServiceAccount name (including generated -pre-deploy names)"
  value       = local.members
}

output "bucket_bindings" {
  description = "Bucket IAM bindings written by this module: one entry per ServiceAccount and bucket grant"
  value = [
    for binding in google_storage_bucket_iam_member.this : {
      bucket = binding.bucket
      role   = binding.role
      member = binding.member
    }
  ]
}

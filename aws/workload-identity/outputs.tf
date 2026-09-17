output "role_arns" {
  description = "IAM role ARN per group"
  value       = { for group_name, role in aws_iam_role.this : group_name => role.arn }
}

output "role_names" {
  description = "IAM role name per group"
  value       = { for group_name, role in aws_iam_role.this : group_name => role.name }
}

output "principals" {
  description = "Principal identifiers per group, in the form resource-side grants accept (the role ARN). Same shape on every cloud."
  value       = { for group_name, role in aws_iam_role.this : group_name => [role.arn] }
}

output "association_ids" {
  description = "EKS Pod Identity association ID per subject, keyed <group>/<association key>"
  value       = { for key, association in aws_eks_pod_identity_association.this : key => association.association_id }
}

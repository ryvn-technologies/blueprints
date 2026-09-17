output "principals" {
  description = "Principal identifiers per group, in the form resource-side grants accept (principal:// members, one per subject). Same shape on every cloud."
  value = {
    for group_name in keys(var.role_groups) :
    group_name => [for key, subject in local.subjects : local.members[key] if subject.group == group_name]
  }
}

output "members" {
  description = "principal:// member per subject, keyed <group>/<association key>"
  value       = local.members
}

output "project_number" {
  description = "Project number used in the principal identifiers"
  value       = local.project_number
}

output "registry_host" {
  description = "Registry endpoint host (e.g. us-central1-docker.pkg.dev)"
  value       = local.registry_host
}

output "repository_id" {
  description = "Artifact Registry repository id (short name, including the random suffix)"
  value       = google_artifact_registry_repository.this.repository_id
}

output "repository_name" {
  description = "Fully qualified Artifact Registry resource name"
  value       = google_artifact_registry_repository.this.id
}

output "destination_base" {
  description = "Base image reference under which mirrored artifacts are pushed: <host>/<project>/<repository>"
  value       = "${local.registry_host}/${var.project_id}/${google_artifact_registry_repository.this.repository_id}"
}

output "path_prefix" {
  description = "Path prepended to the source image path when pulling from this registry (RegistryMirror.pathPrefix)"
  value       = "${var.project_id}/${google_artifact_registry_repository.this.repository_id}"
}

output "region" {
  description = "Artifact Registry location"
  value       = google_artifact_registry_repository.this.location
}

output "project_id" {
  description = "GCP project that owns the repository"
  value       = var.project_id
}

output "registry_definition" {
  description = "Registry definition in the shape of the Ryvn registry API (GoogleArtifactRegistry). Contains no secrets."
  value = {
    type      = "googleArtifactRegistry"
    url       = local.registry_host
    projectId = var.project_id
    location  = google_artifact_registry_repository.this.location
  }
}

output "push_identity" {
  description = "Non-secret description of how the artifact copier authenticates to push"
  value = {
    method          = "gcpWorkloadIdentity"
    namespace       = var.push_namespace
    serviceAccounts = var.push_service_accounts
    members         = local.push_members
    role            = local.push_role
  }
}

output "pull_identity" {
  description = "Non-secret description of how cluster nodes and the agent authenticate to pull"
  value = {
    method               = "gcpWorkloadIdentity"
    namespace            = var.pull_namespace
    serviceAccounts      = local.node_service_accounts
    agentServiceAccounts = var.pull_service_accounts
    serviceAccountEmails = var.pull_service_account_emails
    members              = local.pull_members
    role                 = local.pull_role
    detected             = local.detect_node_identities
  }
}

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.6.0"

  backend "kubernetes" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "random_id" "suffix" {
  byte_length = 4
}

data "google_project" "this" {
  project_id = var.project_id
}

data "google_container_cluster" "this" {
  count = local.detect_node_identities ? 1 : 0

  name     = var.cluster_name
  location = coalesce(var.cluster_location, var.region)
  project  = var.project_id
}

locals {
  # Artifact Registry repository ids are lowercase [a-z0-9-], 1-63 chars,
  # starting with a letter. Only the base is truncated so the suffix survives.
  sanitized_name = trim(replace(lower(coalesce(var.registry_name, var.name_prefix)), "/[^a-z0-9-]+/", "-"), "-")
  lettered_name  = can(regex("^[a-z]", local.sanitized_name)) ? local.sanitized_name : trimsuffix("registry-${local.sanitized_name}", "-")
  base_name      = trimsuffix(substr(local.lettered_name, 0, 54), "-")
  repository_id  = "${local.base_name}-${random_id.suffix.hex}"
  registry_host  = "${var.region}-docker.pkg.dev"

  all_labels = merge(var.labels, {
    terraform   = "true"
    environment = var.environment
    managed-by  = "ryvn"
  })

  # Node service accounts detected from the GKE cluster are merged with the
  # explicit list. Attached clusters must pass them explicitly.
  detect_node_identities = var.cluster_name != ""

  default_compute_service_account = "${data.google_project.this.number}-compute@developer.gserviceaccount.com"

  detected_node_service_accounts = local.detect_node_identities ? distinct([
    for pool in data.google_container_cluster.this[0].node_pool :
    pool.node_config[0].service_account == "default" || pool.node_config[0].service_account == ""
    ? local.default_compute_service_account
    : pool.node_config[0].service_account
  ]) : []

  node_service_accounts = distinct(concat(var.node_service_accounts, local.detected_node_service_accounts))

  push_role = "roles/artifactregistry.writer"
  pull_role = "roles/artifactregistry.reader"

  # Workload Identity Federation for GKE principals for the copier job
  # service accounts. No Google service account or key is created.
  push_members = [
    for sa in var.push_service_accounts :
    "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.push_namespace}/sa/${sa}"
  ]

  pull_members = [for sa in local.node_service_accounts : "serviceAccount:${sa}"]
}

resource "google_project_service" "artifact_registry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "this" {
  project       = var.project_id
  location      = var.region
  repository_id = local.repository_id
  format        = "DOCKER"
  description   = "Ryvn managed registry mirror for environment ${var.environment}"
  labels        = local.all_labels

  docker_config {
    immutable_tags = var.immutable_tags
  }

  depends_on = [google_project_service.artifact_registry]

  lifecycle {
    prevent_destroy = false
    precondition {
      condition     = !var.require_node_pull_grant || length(local.node_service_accounts) > 0
      error_message = "No node service accounts were resolved for kubelet pull access. Set node_service_accounts explicitly (required for attached clusters) or set require_node_pull_grant = false."
    }
    precondition {
      condition     = length(var.push_service_accounts) > 0
      error_message = "At least one push service account is required so the artifact copier can write to the repository."
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "push" {
  for_each = toset(local.push_members)

  project    = google_artifact_registry_repository.this.project
  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = local.push_role
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "pull" {
  for_each = toset(local.pull_members)

  project    = google_artifact_registry_repository.this.project
  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = local.pull_role
  member     = each.value
}

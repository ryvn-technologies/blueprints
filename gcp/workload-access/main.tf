terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  required_version = ">= 1.0.0"

  backend "kubernetes" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {
  count      = var.project_number == "" ? 1 : 0
  project_id = var.project_id
}

locals {
  project_number = var.project_number != "" ? var.project_number : data.google_project.this[0].number

  # Each named ServiceAccount optionally also covers the <name>-pre-deploy
  # ServiceAccount that Ryvn's pre-deploy hook Job runs as.
  service_accounts = toset(flatten([
    for service_account in var.service_accounts : concat(
      [trimspace(service_account)],
      var.include_pre_deploy ? ["${trimspace(service_account)}-pre-deploy"] : [],
    ) if trimspace(service_account) != ""
  ]))

  # Workload Identity Federation for GKE: the Kubernetes ServiceAccount is the
  # IAM principal, so no Google service account or annotation is needed.
  members = {
    for service_account in local.service_accounts :
    service_account => "principal://iam.googleapis.com/projects/${local.project_number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${service_account}"
  }

  bucket_grants = [for grant in var.grants : grant if grant.kind == "bucket"]

  bucket_bindings = {
    for pair in setproduct(sort(tolist(local.service_accounts)), local.bucket_grants) :
    "${pair[0]}/${pair[1].target}/${pair[1].role}" => {
      member = local.members[pair[0]]
      bucket = pair[1].target
      role   = pair[1].role
    }
  }
}

resource "google_storage_bucket_iam_member" "this" {
  for_each = local.bucket_bindings

  bucket = each.value.bucket
  role   = each.value.role
  member = each.value.member
}

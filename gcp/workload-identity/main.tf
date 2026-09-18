terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  # optional() attribute defaults on the role_groups variable need 1.3+.
  required_version = ">= 1.3.0"

  backend "kubernetes" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# The project number is needed for principal:// identifiers. Accept it as an
# input, or resolve it here (requires resourcemanager.projects.get).
data "google_project" "this" {
  count = var.project_number == "" ? 1 : 0

  project_id = var.project_id
}

locals {
  project_number = var.project_number != "" ? var.project_number : data.google_project.this[0].number
  workload_pool  = "${var.project_id}.svc.id.goog"

  # One entry per Kubernetes subject, keyed "<group>/<association key>".
  subjects = merge([
    for group_name, group in var.role_groups : {
      for assoc_key, assoc in group.associations :
      "${group_name}/${assoc_key}" => {
        group           = group_name
        namespace       = assoc.namespace
        service_account = assoc.service_account
      }
    }
  ]...)

  # With Workload Identity Federation for GKE the Kubernetes ServiceAccount is
  # itself an IAM principal. Nothing is created for it; it is addressed directly.
  members = {
    for key, subject in local.subjects :
    key => "principal://iam.googleapis.com/projects/${local.project_number}/locations/global/workloadIdentityPools/${local.workload_pool}/subject/ns/${subject.namespace}/sa/${subject.service_account}"
  }

  # One IAM binding per (binding, subject) pair within a group, keyed
  # "<binding key>/<group>/<association key>".
  bucket_bindings = merge([
    for group_name, group in var.role_groups : merge([
      for bucket_key, bucket in group.buckets : {
        for subject_key, subject in local.subjects :
        "${bucket_key}/${subject_key}" => {
          bucket = bucket.name
          role   = bucket.role
          member = local.members[subject_key]
        } if subject.group == group_name
      }
    ]...)
  ]...)

  project_bindings = merge([
    for group_name, group in var.role_groups : merge([
      for role_key, binding in group.project_roles : {
        for subject_key, subject in local.subjects :
        "${role_key}/${subject_key}" => {
          role      = binding.role
          condition = binding.condition
          member    = local.members[subject_key]
        } if subject.group == group_name
      }
    ]...)
  ]...)
}

# Non-authoritative so bindings from other modules on the same bucket are left alone.
resource "google_storage_bucket_iam_member" "this" {
  for_each = local.bucket_bindings

  bucket = each.value.bucket
  role   = each.value.role
  member = each.value.member
}

# Project-level roles for services without resource-level IAM (Cloud SQL,
# Memorystore). The condition narrows the binding to specific resources.
resource "google_project_iam_member" "this" {
  for_each = local.project_bindings

  project = var.project_id
  role    = each.value.role
  member  = each.value.member

  dynamic "condition" {
    for_each = each.value.condition == null ? [] : [each.value.condition]

    content {
      title       = condition.value.title
      expression  = condition.value.expression
      description = condition.value.description
    }
  }
}
# Distributed to BYOC hubs as a public module (github.com/ryvn-technologies/blueprints).

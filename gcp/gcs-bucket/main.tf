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
  required_version = ">= 1.0.0"

  backend "kubernetes" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  # GCS bucket names are globally unique, 3-63 characters, lowercase letters,
  # digits, hyphens and underscores. Trim the prefix so the suffix always fits.
  base_name   = coalesce(trim(substr(trim(replace(lower(coalesce(var.bucket_name, var.name_prefix)), "/[^a-z0-9]+/", "-"), "-"), 0, 54), "-"), "bucket")
  bucket_name = "${local.base_name}-${random_id.suffix.hex}"

  # GCS labels allow lowercase letters, digits, underscores and hyphens only.
  all_labels = merge(var.labels, {
    terraform   = "true"
    environment = lower(replace(var.environment, "/[^A-Za-z0-9_-]/", "-"))
  })

  has_expiration            = var.expiration_days > 0
  has_noncurrent_expiration = var.versioning && var.noncurrent_version_expiration_days > 0
}

resource "google_storage_bucket" "this" {
  name     = local.bucket_name
  project  = var.project_id
  location = var.region

  storage_class = "STANDARD"
  force_destroy = !var.deletion_protection

  # Uniform bucket-level access disables per-object ACLs so bucket IAM is the
  # only access path, which is what the workload identity module writes to.
  uniform_bucket_level_access = true
  public_access_prevention    = var.public_access ? "inherited" : "enforced"

  versioning {
    enabled = var.versioning
  }

  # with_state keeps the current-version rule from also deleting noncurrent
  # versions when versioning is on.
  dynamic "lifecycle_rule" {
    for_each = local.has_expiration ? [1] : []
    content {
      action {
        type = "Delete"
      }
      condition {
        age        = var.expiration_days
        with_state = "LIVE"
      }
    }
  }

  dynamic "lifecycle_rule" {
    for_each = local.has_noncurrent_expiration ? [1] : []
    content {
      action {
        type = "Delete"
      }
      condition {
        days_since_noncurrent_time = var.noncurrent_version_expiration_days
        with_state                 = "ARCHIVED"
      }
    }
  }

  # GCS has a single response_header list covering both request headers the
  # browser may send and response headers it may read, so the two are merged.
  dynamic "cors" {
    for_each = var.cors_rules
    content {
      origin = cors.value.allowed_origins
      method = [
        for method in cors.value.allowed_methods :
        upper(trimspace(method))
      ]
      response_header = distinct(concat(cors.value.allowed_headers, cors.value.expose_headers))
      max_age_seconds = cors.value.max_age_seconds
    }
  }

  dynamic "encryption" {
    for_each = var.kms_key_name == "" ? [] : [1]
    content {
      default_kms_key_name = var.kms_key_name
    }
  }

  labels = local.all_labels
}

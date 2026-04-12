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
  name = "${var.installation_name}-${random_id.suffix.hex}"

  # Map simplified version to GCP format
  redis_version_map = {
    "6"   = "REDIS_6_X"
    "7"   = "REDIS_7_0"
    "7.2" = "REDIS_7_2"
  }
  redis_version = local.redis_version_map[var.redis_version]

  all_labels = merge(var.labels, {
    terraform   = "true"
    environment = var.environment
  })
}

resource "google_redis_instance" "this" {
  name         = local.name
  display_name = "${var.installation_name} (${var.environment})"
  project      = var.project_id
  region       = var.region

  # Engine
  redis_version = local.redis_version

  # Compute
  tier           = var.tier
  memory_size_gb = var.memory_size_gb

  # Network
  authorized_network = var.authorized_network
  connect_mode       = var.connect_mode
  reserved_ip_range  = var.reserved_ip_range

  # Authentication
  auth_enabled = var.auth_enabled

  # Encryption
  transit_encryption_mode = var.transit_encryption_enabled ? "SERVER_AUTHENTICATION" : "DISABLED"

  # Redis configuration
  redis_configs = var.redis_configs

  # Maintenance
  dynamic "maintenance_policy" {
    for_each = var.maintenance_day != null ? [1] : []
    content {
      weekly_maintenance_window {
        day = var.maintenance_day
        start_time {
          hours   = var.maintenance_hour
          minutes = 0
          seconds = 0
          nanos   = 0
        }
      }
    }
  }

  labels = local.all_labels
}

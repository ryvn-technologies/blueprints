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
  name             = "${var.name_prefix}-${random_id.suffix.hex}"
  database_version = "POSTGRES_${var.postgres_version}"

  all_labels = merge(var.labels, {
    terraform        = "true"
    ryvn-environment = var.environment
  })

  # pg_cron database flags (conditional on database_name being set)
  pg_cron_flags = var.database_name != null ? [
    { name = "cloudsql.enable_pg_cron", value = "on" },
    { name = "cron.database_name", value = var.database_name },
  ] : []

  database_flags = local.pg_cron_flags
}

resource "google_sql_database_instance" "this" {
  name             = local.name
  database_version = local.database_version
  region           = var.region
  project          = var.project_id

  # Terraform-level deletion protection
  deletion_protection = var.deletion_protection

  # Set the root (postgres) user password
  root_password = var.database_password

  settings {
    # Compute
    tier    = var.tier
    edition = var.edition

    # Availability
    availability_type = var.high_availability ? "REGIONAL" : "ZONAL"

    # Storage
    disk_size       = var.storage_gb
    disk_type       = var.disk_type
    disk_autoresize = true

    # Backup
    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = var.point_in_time_recovery_enabled
      start_time                     = "03:00"
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = var.backup_retention_count
        retention_unit   = "COUNT"
      }
    }

    # Network
    ip_configuration {
      ipv4_enabled    = var.publicly_accessible
      private_network = var.private_network
      ssl_mode        = "ENCRYPTED_ONLY"

      dynamic "authorized_networks" {
        for_each = var.publicly_accessible ? var.allowed_cidr_blocks : []
        content {
          name  = "allowed-${authorized_networks.key}"
          value = authorized_networks.value
        }
      }
    }

    # Maintenance
    maintenance_window {
      day          = 7 # Sunday
      hour         = 4 # 4 AM UTC
      update_track = "stable"
    }

    # Query Insights
    insights_config {
      query_insights_enabled  = var.query_insights_enabled
      query_string_length     = 4096
      record_application_tags = true
      record_client_address   = true
      query_plans_per_minute  = 5
    }

    # Database flags (pg_cron when database_name is set)
    dynamic "database_flags" {
      for_each = local.database_flags
      content {
        name  = database_flags.value.name
        value = database_flags.value.value
      }
    }

    # GCP API-level deletion protection
    deletion_protection_enabled = var.deletion_protection

    user_labels = local.all_labels
  }

  lifecycle {
    precondition {
      condition     = var.private_network != null || var.publicly_accessible
      error_message = "At least one of private_network or publicly_accessible must be set. The instance would otherwise be unreachable."
    }
  }
}

# Default database
resource "google_sql_database" "this" {
  count = var.database_name != null ? 1 : 0

  name     = var.database_name
  instance = google_sql_database_instance.this.name
  project  = var.project_id
}

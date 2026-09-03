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
  name                  = "${var.name_prefix}-${random_id.suffix.hex}"
  database_version      = "POSTGRES_${var.postgres_version}"
  backups_enabled       = var.backup_retention_days > 0
  database_username     = trimspace(var.database_username)
  uses_builtin_postgres = local.database_username == "postgres"
  # Cloud SQL ships with a built-in postgres database; creating it again fails.
  creates_database = var.database_name != null && var.database_name != "postgres"

  transaction_log_retention_days = local.backups_enabled ? min(var.backup_retention_days, 7) : null

  all_labels = merge(var.labels, {
    terraform   = "true"
    environment = var.environment
  })

  # Enable pg_cron when an app database is requested, but keep cron on the
  # built-in postgres database so destroying the app database is less likely to
  # be blocked by background connections.
  pg_cron_flags = var.database_name != null ? [
    { name = "cloudsql.enable_pg_cron", value = "on" },
    { name = "cron.database_name", value = "postgres" },
  ] : []

  database_flags = local.pg_cron_flags
}

# sqladmin.googleapis.com is a project prerequisite, not something Terraform
# manages here: the agent has no serviceusage permissions. Installations that
# managed it before forget it without calling the API.
removed {
  from = google_project_service.sqladmin

  lifecycle {
    destroy = false
  }
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
    disk_size             = var.storage_gb
    disk_type             = var.disk_type
    disk_autoresize       = true
    disk_autoresize_limit = var.max_storage_gb > 0 ? var.max_storage_gb : null

    # Backup
    backup_configuration {
      enabled                        = local.backups_enabled
      point_in_time_recovery_enabled = local.backups_enabled ? var.point_in_time_recovery_enabled : false
      start_time                     = local.backups_enabled ? "03:00" : null
      transaction_log_retention_days = local.transaction_log_retention_days

      dynamic "backup_retention_settings" {
        for_each = local.backups_enabled ? [1] : []
        content {
          retained_backups = var.backup_retention_days
          retention_unit   = "COUNT"
        }
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
    ignore_changes = [
      settings[0].disk_size,
    ]

    precondition {
      condition     = var.private_network != null || var.publicly_accessible
      error_message = "At least one of private_network or publicly_accessible must be set. The instance would otherwise be unreachable."
    }
  }
}

# Marks the instance as Ryvn-managed. The agent's Cloud SQL write permissions
# are granted through a role binding conditioned on this tag, so it has to be
# attached before any database or user is created on the instance.
resource "google_tags_location_tag_binding" "managed" {
  count = var.managed_tag_value != "" ? 1 : 0

  parent    = "//sqladmin.googleapis.com/projects/${var.project_id}/instances/${google_sql_database_instance.this.name}"
  tag_value = var.managed_tag_value
  location  = var.region
}

# Default database
resource "google_sql_database" "this" {
  count = local.creates_database ? 1 : 0

  depends_on = [google_tags_location_tag_binding.managed]

  name     = var.database_name
  instance = google_sql_database_instance.this.name
  project  = var.project_id
}

# Cloud SQL already includes the built-in postgres user. Reuse it when
# requested, otherwise create a matching built-in user so the blueprint
# username is honored on GCP as well. Cloud SQL automatically grants
# cloudsqlsuperuser to built-in PostgreSQL users.
resource "google_sql_user" "application" {
  count = local.uses_builtin_postgres ? 0 : 1

  depends_on = [google_tags_location_tag_binding.managed]

  name     = local.database_username
  instance = google_sql_database_instance.this.name
  project  = var.project_id
  password = var.database_password
}

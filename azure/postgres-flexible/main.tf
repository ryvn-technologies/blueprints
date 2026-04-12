terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0.0"

  backend "kubernetes" {}
}

provider "azurerm" {
  features {}
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name = "${var.name_prefix}-${random_id.suffix.hex}"

  delegated_subnet_id = var.delegated_subnet_id == null ? "" : trimspace(var.delegated_subnet_id)
  private_dns_zone_id = var.private_dns_zone_id == null ? "" : trimspace(var.private_dns_zone_id)

  # Private networking now consumes a shared delegated subnet and private DNS zone
  # created during environment provisioning.
  private_access   = local.delegated_subnet_id != "" || local.private_dns_zone_id != ""
  storage_limit_gb = max(var.storage_gb, 32)

  all_tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment
  })
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = local.name
  resource_group_name = var.resource_group_name
  location            = var.location

  # Engine
  version = var.postgres_version

  # Compute
  sku_name = var.sku_name

  # Storage
  storage_mb        = local.storage_limit_gb * 1024
  auto_grow_enabled = var.auto_grow_enabled

  # Credentials
  administrator_login    = var.database_username
  administrator_password = var.database_password

  # Network
  delegated_subnet_id           = local.private_access ? local.delegated_subnet_id : null
  private_dns_zone_id           = local.private_access ? local.private_dns_zone_id : null
  public_network_access_enabled = !local.private_access

  # Backup
  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  # High availability
  dynamic "high_availability" {
    for_each = var.high_availability ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  tags = local.all_tags

  lifecycle {
    ignore_changes = [
      storage_mb,
      zone,
      high_availability[0].standby_availability_zone,
    ]

    precondition {
      condition     = (local.delegated_subnet_id == "") == (local.private_dns_zone_id == "")
      error_message = "Private PostgreSQL requires both delegated_subnet_id and private_dns_zone_id."
    }
  }
}

# Default database
resource "azurerm_postgresql_flexible_server_database" "this" {
  count = var.database_name != null ? 1 : 0

  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Deletion protection via management lock
resource "azurerm_management_lock" "this" {
  count = var.deletion_protection ? 1 : 0

  name       = "${local.name}-delete-lock"
  scope      = azurerm_postgresql_flexible_server.this.id
  lock_level = "CanNotDelete"
  notes      = "Prevent accidental deletion of ${local.name}"
}

# Server configurations: enable pg_cron while keeping it on the built-in
# postgres database so destroying the app database is less likely to be blocked.
resource "azurerm_postgresql_flexible_server_configuration" "shared_preload_libraries" {
  count = var.database_name != null ? 1 : 0

  name      = "shared_preload_libraries"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "pg_cron"
}

resource "azurerm_postgresql_flexible_server_configuration" "azure_extensions" {
  count = var.database_name != null ? 1 : 0

  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "PG_CRON"
}

resource "azurerm_postgresql_flexible_server_configuration" "cron_database_name" {
  count = var.database_name != null ? 1 : 0

  name      = "cron.database_name"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "postgres"

  depends_on = [
    azurerm_postgresql_flexible_server_configuration.shared_preload_libraries,
    azurerm_postgresql_flexible_server_configuration.azure_extensions,
  ]
}

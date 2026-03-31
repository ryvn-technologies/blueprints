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

  all_tags = merge(var.tags, {
    Terraform              = "true"
    "ryvn.app/environment" = var.environment
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
  storage_mb        = var.storage_gb * 1024
  auto_grow_enabled = var.auto_grow_enabled

  # Credentials
  administrator_login    = var.database_username
  administrator_password = var.database_password

  # Network
  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = var.delegated_subnet_id != null ? var.private_dns_zone_id : null
  public_network_access_enabled = var.delegated_subnet_id == null

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
    precondition {
      condition     = !(var.delegated_subnet_id != null && var.private_dns_zone_id == null)
      error_message = "private_dns_zone_id is required when delegated_subnet_id is set."
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

# Server configurations: pg_cron (matching AWS module defaults)
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
  value     = var.database_name

  depends_on = [
    azurerm_postgresql_flexible_server_configuration.shared_preload_libraries,
    azurerm_postgresql_flexible_server_configuration.azure_extensions,
  ]
}

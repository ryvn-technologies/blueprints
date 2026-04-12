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
  name = "${var.installation_name}-${random_id.suffix.hex}"

  # Derive family from SKU: C for Basic/Standard, P for Premium
  family = var.sku_name == "Premium" ? "P" : "C"

  # Normalize optional network inputs so null/empty values both mean "not configured".
  private_endpoint_subnet_id = var.private_endpoint_subnet_id == null ? "" : trimspace(var.private_endpoint_subnet_id)
  private_dns_zone_id        = var.private_dns_zone_id == null ? "" : trimspace(var.private_dns_zone_id)

  # Preferred private networking mode for new installs.
  private_link_enabled = local.private_endpoint_subnet_id != ""

  all_tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment
  })
}

resource "azurerm_redis_cache" "this" {
  name                = local.name
  resource_group_name = var.resource_group_name
  location            = var.location

  # SKU
  sku_name = var.sku_name
  family   = local.family
  capacity = var.capacity

  # Redis version
  redis_version = var.redis_version

  # Network
  public_network_access_enabled = !local.private_link_enabled

  # TLS
  minimum_tls_version = "1.2"

  # Replication (Premium only)
  replicas_per_primary = var.sku_name == "Premium" ? var.replicas_per_primary : null
  shard_count          = var.sku_name == "Premium" ? var.shard_count : null

  # Zones (Premium only)
  zones = var.sku_name == "Premium" && length(var.zones) > 0 ? var.zones : null

  # Redis configuration
  redis_configuration {
    maxmemory_policy = var.maxmemory_policy
  }

  # Maintenance
  dynamic "patch_schedule" {
    for_each = var.patch_day != null && var.sku_name != "Basic" ? [1] : []
    content {
      day_of_week    = var.patch_day
      start_hour_utc = var.patch_hour
    }
  }

  tags = local.all_tags

  lifecycle {
    precondition {
      condition     = !local.private_link_enabled || local.private_dns_zone_id != ""
      error_message = "private_dns_zone_id is required when private_endpoint_subnet_id is set."
    }
    precondition {
      condition     = var.replicas_per_primary == 0 || var.sku_name == "Premium"
      error_message = "replicas_per_primary requires Premium SKU."
    }
    precondition {
      condition     = var.shard_count == 0 || var.sku_name == "Premium"
      error_message = "shard_count (clustering) requires Premium SKU."
    }
    precondition {
      condition     = var.sku_name != "Premium" || (var.capacity >= 1 && var.capacity <= 5)
      error_message = "Premium SKU capacity must be between 1 and 5."
    }
  }
}

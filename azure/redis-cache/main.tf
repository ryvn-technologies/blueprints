terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.61"
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

  # Normalize optional network inputs so null/empty values both mean "not configured".
  private_endpoint_subnet_id = var.private_endpoint_subnet_id == null ? "" : trimspace(var.private_endpoint_subnet_id)
  private_dns_zone_id        = var.private_dns_zone_id == null ? "" : trimspace(var.private_dns_zone_id)

  # Preferred private networking mode for new installs.
  private_link_enabled = local.private_endpoint_subnet_id != ""

  # Empty string and null both mean "use service-managed encryption".
  customer_managed_key_id          = var.customer_managed_key_id == null ? "" : trimspace(var.customer_managed_key_id)
  customer_managed_key_identity_id = var.customer_managed_key_identity_id == null ? "" : trimspace(var.customer_managed_key_identity_id)
  customer_managed_key_enabled     = local.customer_managed_key_id != ""

  all_tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment
  })
}

resource "azurerm_managed_redis" "this" {
  name                = local.name
  resource_group_name = var.resource_group_name
  location            = var.location

  # SKU
  sku_name = var.sku_name

  # High availability
  high_availability_enabled = var.high_availability_enabled

  # Network
  public_network_access = local.private_link_enabled ? "Disabled" : "Enabled"

  default_database {
    access_keys_authentication_enabled = true
    client_protocol                    = "Encrypted"
    clustering_policy                  = var.clustering_policy
    eviction_policy                    = var.eviction_policy

    # Null disables RDB persistence.
    persistence_redis_database_backup_frequency = var.rdb_backup_frequency
  }

  # Customer-managed key. The cache authenticates to Key Vault with the
  # user-assigned identity, so both blocks are required together.
  dynamic "identity" {
    for_each = local.customer_managed_key_enabled ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [local.customer_managed_key_identity_id]
    }
  }

  dynamic "customer_managed_key" {
    for_each = local.customer_managed_key_enabled ? [1] : []
    content {
      key_vault_key_id          = local.customer_managed_key_id
      user_assigned_identity_id = local.customer_managed_key_identity_id
    }
  }

  tags = local.all_tags

  lifecycle {
    precondition {
      condition     = !local.private_link_enabled || local.private_dns_zone_id != ""
      error_message = "private_dns_zone_id is required when private_endpoint_subnet_id is set."
    }
    precondition {
      condition     = local.customer_managed_key_enabled == (local.customer_managed_key_identity_id != "")
      error_message = "customer_managed_key_id and customer_managed_key_identity_id must be set together."
    }
  }
}

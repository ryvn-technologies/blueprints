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
  # Shared keys are disabled on the account, so the provider must reach the
  # blob data plane with its own Entra identity.
  storage_use_azuread = true
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  # Storage account names are globally unique, 3-24 characters, lowercase
  # letters and digits only. The 8-char hex suffix leaves 16 chars of prefix.
  raw_name     = lower(coalesce(var.bucket_name, var.name_prefix))
  account_base = coalesce(substr(replace(local.raw_name, "/[^a-z0-9]/", ""), 0, 16), "bucket")
  account_name = "${local.account_base}${random_id.suffix.hex}"

  # Container names are 3-63 characters, lowercase letters, digits and single
  # hyphens, and cannot start or end with a hyphen. This is what the blueprint
  # surfaces as the bucket name.
  container_base = coalesce(trim(substr(trim(replace(local.raw_name, "/[^a-z0-9]+/", "-"), "-"), 0, 54), "-"), "bucket")
  container_name = "${local.container_base}-${random_id.suffix.hex}"

  all_tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment
  })

  has_expiration            = var.expiration_days > 0
  has_noncurrent_expiration = var.versioning && var.noncurrent_version_expiration_days > 0
  has_lifecycle             = local.has_expiration || local.has_noncurrent_expiration
}

resource "azurerm_storage_account" "this" {
  name                = local.account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_kind               = "StorageV2"
  account_tier               = "Standard"
  account_replication_type   = var.replication_type
  min_tls_version            = "TLS1_2"
  https_traffic_only_enabled = true

  # Anonymous blob access is opt-in per container and additionally gated at
  # the account level. Account keys are disabled: access is Entra ID / RBAC
  # only, and presigned URLs must use user-delegation SAS.
  allow_nested_items_to_be_public = var.public_access
  shared_access_key_enabled       = var.shared_access_key_enabled
  default_to_oauth_authentication = true
  public_network_access_enabled   = var.public_network_access

  dynamic "identity" {
    for_each = local.cmk_enabled ? [1] : []
    content {
      type = "SystemAssigned"
    }
  }

  blob_properties {
    versioning_enabled = var.versioning

    dynamic "cors_rule" {
      for_each = var.cors_rules
      content {
        allowed_origins    = cors_rule.value.allowed_origins
        allowed_methods    = [for method in cors_rule.value.allowed_methods : upper(trimspace(method))]
        allowed_headers    = cors_rule.value.allowed_headers
        exposed_headers    = cors_rule.value.expose_headers
        max_age_in_seconds = cors_rule.value.max_age_seconds
      }
    }
  }

  tags = local.all_tags
}

# Customer-managed key: the account's system-assigned identity must be able to
# wrap/unwrap with the key before encryption is switched over to it, so the
# key binding is a separate resource applied after the role assignment.
locals {
  cmk_enabled      = var.encryption_key_id != ""
  cmk_key_vault_id = local.cmk_enabled ? regex("^(.*/providers/Microsoft\\.KeyVault/vaults/[^/]+)/keys/[^/]+$", var.encryption_key_id)[0] : ""
  cmk_key_name     = local.cmk_enabled ? regex("/keys/([^/]+)$", var.encryption_key_id)[0] : ""
}

data "azurerm_key_vault_key" "cmk" {
  count        = local.cmk_enabled ? 1 : 0
  name         = local.cmk_key_name
  key_vault_id = local.cmk_key_vault_id
}

resource "azurerm_role_assignment" "cmk" {
  count                = local.cmk_enabled ? 1 : 0
  scope                = local.cmk_key_vault_id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_storage_account.this.identity[0].principal_id
}

resource "azurerm_storage_account_customer_managed_key" "this" {
  count              = local.cmk_enabled ? 1 : 0
  storage_account_id = azurerm_storage_account.this.id
  key_vault_key_id   = data.azurerm_key_vault_key.cmk[0].versionless_id

  depends_on = [azurerm_role_assignment.cmk]
}

resource "azurerm_storage_container" "this" {
  name                  = local.container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = var.public_access ? "blob" : "private"
}

# Lifecycle rules live on the account and are scoped to this container by
# prefix, so the account's other containers (there are none) are untouched.
resource "azurerm_storage_management_policy" "this" {
  count = local.has_lifecycle ? 1 : 0

  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "ryvn-bucket-lifecycle"
    enabled = true

    filters {
      prefix_match = ["${azurerm_storage_container.this.name}/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      dynamic "base_blob" {
        for_each = local.has_expiration ? [1] : []
        content {
          delete_after_days_since_modification_greater_than = var.expiration_days
        }
      }

      dynamic "version" {
        for_each = local.has_noncurrent_expiration ? [1] : []
        content {
          delete_after_days_since_creation = var.noncurrent_version_expiration_days
        }
      }
    }
  }
}

# Deletion protection: a CanNotDelete lock on the account blocks deleting the
# account and, transitively, the container. Terraform must remove the lock
# (set deletion_protection = false and apply) before the bucket can be destroyed.
resource "azurerm_management_lock" "this" {
  count = var.deletion_protection ? 1 : 0

  name       = "${local.account_name}-nodelete"
  scope      = azurerm_storage_account.this.id
  lock_level = "CanNotDelete"
  notes      = "Managed by Ryvn: deletion protection for bucket ${local.container_name}"
}

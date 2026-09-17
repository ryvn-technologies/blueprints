variable "location" {
  description = "Azure region (e.g. eastus, westeurope)"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
}

# Identity
variable "name_prefix" {
  description = "Prefix for the database server name. A stable random suffix is appended automatically."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. production, staging)"
  type        = string
}

# Engine
variable "postgres_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"

  validation {
    condition     = contains(["13", "14", "15", "16", "17"], var.postgres_version)
    error_message = "Supported PostgreSQL versions are 13, 14, 15, 16, 17."
  }
}

# Compute
variable "sku_name" {
  description = "Azure SKU name (e.g. GP_Standard_D2s_v3, B_Standard_B2s, MO_Standard_E4s_v3). Burstable (B_) SKUs do not support zone-redundant HA."
  type        = string
  default     = "GP_Standard_D2s_v3"
}

# Storage
variable "storage_gb" {
  description = "Storage size in GiB. Can only be increased, never decreased. Values below 32 GiB are rounded up to Azure's minimum."
  type        = number
  default     = 32

  validation {
    condition     = var.storage_gb >= 1 && var.storage_gb <= 32768
    error_message = "storage_gb must be between 1 and 32768."
  }
}

variable "auto_grow_enabled" {
  description = "Enable automatic storage growth when space is running low"
  type        = bool
  default     = true
}

# High availability
variable "high_availability" {
  description = "Enable zone-redundant high availability with automatic failover"
  type        = bool
  default     = false
}

# Database credentials
variable "database_name" {
  description = "Name of the default database to create"
  type        = string
  default     = null
}

variable "database_username" {
  description = "Local administrator login. Required with password authentication; omit for new Entra-only servers. Changing an existing login can replace the server."
  type        = string
  default     = null

  validation {
    condition     = !var.password_authentication_enabled || try(trimspace(var.database_username) != "", false)
    error_message = "database_username is required when password_authentication_enabled is true."
  }
}

variable "database_password" {
  description = "Local administrator password. Required with password authentication; omit for new Entra-only servers. Minimum 8 characters."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = !var.password_authentication_enabled || try(length(var.database_password) > 0, false)
    error_message = "database_password is required when password_authentication_enabled is true."
  }
}

# Authentication
variable "entra_authentication_enabled" {
  description = "Enable Microsoft Entra authentication. Requires entra_tenant_id and at least one entra_administrators entry. Enabling it restarts the server."
  type        = bool
  default     = false
  nullable    = false
}

variable "password_authentication_enabled" {
  description = "Allow local PostgreSQL password authentication. Disable for Entra-only access."
  type        = bool
  default     = true
  nullable    = false

  validation {
    condition     = var.password_authentication_enabled || var.entra_authentication_enabled
    error_message = "At least one of password_authentication_enabled or entra_authentication_enabled must be true."
  }
}

variable "entra_tenant_id" {
  description = "Microsoft Entra tenant UUID trusted by the server. Required with Entra authentication; leave null when disabled."
  type        = string
  default     = null

  validation {
    condition     = var.entra_authentication_enabled ? can(regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", var.entra_tenant_id)) : var.entra_tenant_id == null
    error_message = "entra_tenant_id must be a UUID when entra_authentication_enabled is true, and null when it is false."
  }
}

variable "entra_administrators" {
  description = "Caller-owned Entra administrators keyed by stable aliases. Use the principal/object ID, not the client ID, and ServicePrincipal for managed identities. These identities receive administrator privileges, not application read/write grants."
  type = map(object({
    object_id      = string
    principal_name = string
    principal_type = string
  }))
  default  = {}
  nullable = false

  validation {
    condition     = var.entra_authentication_enabled ? length(var.entra_administrators) > 0 : length(var.entra_administrators) == 0
    error_message = "entra_administrators must contain at least one administrator when Entra authentication is enabled, and must be empty when disabled."
  }

  validation {
    condition = try(alltrue([
      for administrator in values(var.entra_administrators) :
      can(regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", administrator.object_id)) &&
      trimspace(administrator.principal_name) != "" &&
      contains(["User", "Group", "ServicePrincipal"], administrator.principal_type)
    ]), false)
    error_message = "Each Entra administrator needs a UUID object_id, a nonempty principal_name, and principal_type User, Group, or ServicePrincipal."
  }

  validation {
    condition     = try(length(distinct([for administrator in values(var.entra_administrators) : lower(administrator.object_id)])) == length(var.entra_administrators), false)
    error_message = "Entra administrator object IDs must be distinct."
  }
}

# Encryption
variable "customer_managed_key_id" {
  description = "Key Vault key ID (https://VAULT.vault.azure.net/keys/KEY or a versioned variant) for customer-managed data encryption. Leave empty for service-managed encryption. Requires customer_managed_key_identity_id. Cannot be changed after creation."
  type        = string
  default     = null

  validation {
    condition     = var.customer_managed_key_id == null || trimspace(var.customer_managed_key_id) == "" || can(regex("^https://[^/]+/keys/[^/]+(/[^/]+)?$", trimspace(var.customer_managed_key_id)))
    error_message = "customer_managed_key_id must be a Key Vault key identifier such as https://my-vault.vault.azure.net/keys/my-key."
  }
}

variable "customer_managed_key_identity_id" {
  description = "Resource ID of a user-assigned managed identity that has get, wrapKey, and unwrapKey on the Key Vault key (the Key Vault Crypto Service Encryption User role). Required with customer_managed_key_id."
  type        = string
  default     = null
}

# Protection
variable "deletion_protection" {
  description = "Prevent accidental deletion using an Azure management lock"
  type        = bool
  default     = true
}

# Backup
variable "backup_retention_days" {
  description = "Number of days to retain automated backups (7-35). Azure Flexible Server does not support disabling automated backups."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35. Azure Flexible Server does not support disabling automated backups."
  }
}

variable "geo_redundant_backup_enabled" {
  description = "Enable geo-redundant backups. Cannot be changed after creation."
  type        = bool
  default     = false
}

# Network
variable "delegated_subnet_id" {
  description = "Existing delegated subnet ID for private access. When set with private_dns_zone_id, the server is provisioned privately."
  type        = string
  default     = null
}

variable "private_dns_zone_id" {
  description = "Existing private DNS zone ID for private access. Must be set together with delegated_subnet_id."
  type        = string
  default     = null
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the database (public access mode only). Single IPs are also accepted (treated as /32)."
  type        = list(string)
  default     = []
}

variable "allow_azure_services" {
  description = "Allow access from all Azure services (public access mode only)"
  type        = bool
  default     = false
}

# Tags
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

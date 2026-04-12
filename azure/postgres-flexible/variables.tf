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
  description = "Administrator login name. Cannot be changed after creation."
  type        = string
}

variable "database_password" {
  description = "Administrator password. Minimum 8 characters."
  type        = string
  sensitive   = true
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

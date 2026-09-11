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
variable "installation_name" {
  description = "Prefix for the Managed Redis name. A stable random suffix is appended automatically."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. production, staging)"
  type        = string
}

# SKU
variable "sku_name" {
  description = "Managed Redis SKU: Balanced_B (general purpose, e.g. B0 0.5GB, B1 1GB, B3 3GB, B5 6GB, B10 12GB), ComputeOptimized_X, MemoryOptimized_M, or FlashOptimized_A followed by the size number. See the module README for the full list."
  type        = string
  default     = "Balanced_B1"

  validation {
    condition     = contains(["Balanced_B0", "Balanced_B1", "Balanced_B3", "Balanced_B5", "Balanced_B10", "Balanced_B20", "Balanced_B50", "Balanced_B100", "Balanced_B150", "Balanced_B250", "Balanced_B350", "Balanced_B500", "Balanced_B700", "Balanced_B1000", "ComputeOptimized_X3", "ComputeOptimized_X5", "ComputeOptimized_X10", "ComputeOptimized_X20", "ComputeOptimized_X50", "ComputeOptimized_X100", "ComputeOptimized_X150", "ComputeOptimized_X250", "ComputeOptimized_X350", "ComputeOptimized_X500", "ComputeOptimized_X700", "MemoryOptimized_M10", "MemoryOptimized_M20", "MemoryOptimized_M50", "MemoryOptimized_M100", "MemoryOptimized_M150", "MemoryOptimized_M250", "MemoryOptimized_M350", "MemoryOptimized_M500", "MemoryOptimized_M700", "MemoryOptimized_M1000", "MemoryOptimized_M1500", "MemoryOptimized_M2000", "FlashOptimized_A250", "FlashOptimized_A500", "FlashOptimized_A700", "FlashOptimized_A1000", "FlashOptimized_A1500", "FlashOptimized_A2000", "FlashOptimized_A4500"], var.sku_name)
    error_message = "sku_name must be a supported Azure Managed Redis SKU (see module README)."
  }
}

# High availability
variable "high_availability_enabled" {
  description = "Enable a two-node replicated deployment with a 99.999% SLA. Disable for dev environments. Cannot be changed after creation."
  type        = bool
  default     = true
}

# Database
variable "clustering_policy" {
  description = "Clustering policy for the default database. EnterpriseCluster gives a single endpoint compatible with non-cluster-aware clients; OSSCluster requires cluster-aware clients but scales better; NoCluster disables clustering. Changing this recreates the database and loses data."
  type        = string
  default     = "EnterpriseCluster"

  validation {
    condition     = contains(["EnterpriseCluster", "OSSCluster", "NoCluster"], var.clustering_policy)
    error_message = "clustering_policy must be EnterpriseCluster, OSSCluster, or NoCluster."
  }
}

variable "eviction_policy" {
  description = "Eviction policy when the memory limit is reached."
  type        = string
  default     = "VolatileLRU"

  validation {
    condition     = contains(["AllKeysLFU", "AllKeysLRU", "AllKeysRandom", "VolatileLRU", "VolatileLFU", "VolatileTTL", "VolatileRandom", "NoEviction"], var.eviction_policy)
    error_message = "eviction_policy must be one of AllKeysLFU, AllKeysLRU, AllKeysRandom, VolatileLRU, VolatileLFU, VolatileTTL, VolatileRandom, NoEviction."
  }
}

variable "rdb_backup_frequency" {
  description = "RDB persistence backup frequency for the default database. Null disables persistence."
  type        = string
  default     = null

  validation {
    condition     = var.rdb_backup_frequency == null || contains(["1h", "6h", "12h"], var.rdb_backup_frequency)
    error_message = "rdb_backup_frequency must be 1h, 6h, 12h, or null."
  }
}

# Encryption
variable "customer_managed_key_id" {
  description = "Versioned Key Vault key ID (https://VAULT.vault.azure.net/keys/KEY/VERSION) for customer-managed data encryption. Leave empty for service-managed encryption. Requires customer_managed_key_identity_id. Cannot be changed after creation."
  type        = string
  default     = null

  validation {
    condition     = var.customer_managed_key_id == null || trimspace(var.customer_managed_key_id) == "" || can(regex("^https://[^/]+/keys/[^/]+/[^/]+$", trimspace(var.customer_managed_key_id)))
    error_message = "customer_managed_key_id must be a versioned Key Vault key identifier such as https://my-vault.vault.azure.net/keys/my-key/0123456789abcdef0123456789abcdef."
  }
}

variable "customer_managed_key_identity_id" {
  description = "Resource ID of a user-assigned managed identity that has get, wrapKey, and unwrapKey on the Key Vault key (the Key Vault Crypto Service Encryption User role). Required with customer_managed_key_id."
  type        = string
  default     = null
}

# Network
variable "private_endpoint_subnet_id" {
  description = "Subnet ID for Azure Private Link private endpoints. When set, the cache is accessed privately through a private endpoint."
  type        = string
  default     = null
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for Azure Managed Redis Private Link. Expected zone name is privatelink.redis.azure.net."
  type        = string
  default     = null
}

# Tags
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

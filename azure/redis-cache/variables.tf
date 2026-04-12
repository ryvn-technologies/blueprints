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
  description = "Prefix for the Redis cache name. A stable random suffix is appended automatically."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. production, staging)"
  type        = string
}

# SKU
variable "sku_name" {
  description = "Redis cache tier: Basic (no replication/SLA), Standard (replicated, 99.9% SLA), Premium (clustering, VNet, persistence)"
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku_name)
    error_message = "sku_name must be Basic, Standard, or Premium."
  }
}

variable "capacity" {
  description = "Cache size: 0-6 for Basic/Standard (250MB-53GB), 1-5 for Premium (6GB-120GB)"
  type        = number
  default     = 1

  validation {
    condition     = var.capacity >= 0 && var.capacity <= 6
    error_message = "capacity must be between 0 and 6."
  }
}

# Engine
variable "redis_version" {
  description = "Redis major version"
  type        = string
  default     = "6"

  validation {
    condition     = contains(["4", "6"], var.redis_version)
    error_message = "Supported Redis versions are 4 and 6."
  }
}

# Network
variable "private_endpoint_subnet_id" {
  description = "Subnet ID for Azure Private Link private endpoints. When set, the cache is accessed privately through a private endpoint."
  type        = string
  default     = null
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for Azure Cache for Redis Private Link. Expected zone name is privatelink.redis.cache.windows.net."
  type        = string
  default     = null
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the cache (public access mode only). Single IPs are also accepted (treated as /32)."
  type        = list(string)
  default     = []
}

# Replication (Premium only)
variable "replicas_per_primary" {
  description = "Number of replicas per primary node (Premium SKU only, 0-3)"
  type        = number
  default     = 0

  validation {
    condition     = var.replicas_per_primary >= 0 && var.replicas_per_primary <= 3
    error_message = "replicas_per_primary must be between 0 and 3."
  }
}

variable "shard_count" {
  description = "Number of shards for Redis cluster (Premium SKU only, 0-10). Set to 0 to disable clustering."
  type        = number
  default     = 0

  validation {
    condition     = var.shard_count >= 0 && var.shard_count <= 10
    error_message = "shard_count must be between 0 and 10."
  }
}

variable "zones" {
  description = "Availability zones for the cache (Premium SKU only)"
  type        = list(string)
  default     = []
}

# Redis configuration
variable "maxmemory_policy" {
  description = "Eviction policy when memory limit is reached. Common values: volatile-lru, allkeys-lru, noeviction"
  type        = string
  default     = "volatile-lru"
}

# Maintenance
variable "patch_day" {
  description = "Day of week for maintenance patches (e.g. Monday, Sunday). Leave null to use Azure defaults."
  type        = string
  default     = "Sunday"
}

variable "patch_hour" {
  description = "Start hour (UTC, 0-23) for the maintenance window"
  type        = number
  default     = 4
}

# Tags
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

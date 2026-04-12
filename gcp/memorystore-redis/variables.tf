variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

# Identity
variable "installation_name" {
  description = "Prefix for the Redis instance name. A stable random suffix is appended automatically."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. production, staging)"
  type        = string
}

# Engine
variable "redis_version" {
  description = "Redis version: '6', '7', or '7.2'"
  type        = string
  default     = "7"

  validation {
    condition     = contains(["6", "7", "7.2"], var.redis_version)
    error_message = "Supported Redis versions are 6, 7, and 7.2."
  }
}

# Compute
variable "tier" {
  description = "Service tier: BASIC (no replication) or STANDARD_HA (cross-zone replication with automatic failover)"
  type        = string
  default     = "BASIC"

  validation {
    condition     = contains(["BASIC", "STANDARD_HA"], var.tier)
    error_message = "tier must be BASIC or STANDARD_HA."
  }
}

variable "memory_size_gb" {
  description = "Redis memory size in GiB (1-300)"
  type        = number
  default     = 1

  validation {
    condition     = var.memory_size_gb >= 1 && var.memory_size_gb <= 300
    error_message = "memory_size_gb must be between 1 and 300."
  }
}

# Network
variable "authorized_network" {
  description = "VPC network self_link for private access (e.g. google_compute_network.vpc.self_link). Memorystore is private-only."
  type        = string
}

variable "connect_mode" {
  description = "Connection mode: DIRECT_PEERING or PRIVATE_SERVICE_ACCESS"
  type        = string
  default     = "DIRECT_PEERING"

  validation {
    condition     = contains(["DIRECT_PEERING", "PRIVATE_SERVICE_ACCESS"], var.connect_mode)
    error_message = "connect_mode must be DIRECT_PEERING or PRIVATE_SERVICE_ACCESS."
  }
}

variable "reserved_ip_range" {
  description = "CIDR range for the Redis instance (e.g. 10.0.0.0/29). If not specified, an available range is automatically chosen."
  type        = string
  default     = null
}

# Authentication
variable "auth_enabled" {
  description = "Enable Redis AUTH for additional access control"
  type        = bool
  default     = true
}

# Encryption
variable "transit_encryption_enabled" {
  description = "Enable in-transit encryption (TLS). Clients must support TLS when enabled."
  type        = bool
  default     = true
}

# Redis configuration
variable "redis_configs" {
  description = "Redis configuration parameters (e.g. maxmemory-policy, notify-keyspace-events)"
  type        = map(string)
  default     = {}
}

# Maintenance
variable "maintenance_day" {
  description = "Day of week for maintenance (e.g. SUNDAY, MONDAY). Leave null for no preference."
  type        = string
  default     = "SUNDAY"
}

variable "maintenance_hour" {
  description = "Start hour (UTC, 0-23) for the maintenance window"
  type        = number
  default     = 4
}

# Labels
variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
  default     = {}
}

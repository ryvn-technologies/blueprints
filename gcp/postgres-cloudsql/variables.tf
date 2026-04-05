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
variable "name_prefix" {
  description = "Prefix for the database instance name. A stable random suffix is appended automatically."
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
    condition     = contains(["14", "15", "16", "17"], var.postgres_version)
    error_message = "Supported PostgreSQL versions are 14, 15, 16, 17."
  }
}

# Compute
variable "tier" {
  description = "Machine type for the Cloud SQL instance (e.g. db-custom-2-7680, db-f1-micro, db-perf-optimized-N-2). Format: db-custom-{vCPUs}-{RAM_MB} for standard instances."
  type        = string
  default     = "db-custom-2-7680"
}

variable "edition" {
  description = "Cloud SQL edition. ENTERPRISE_PLUS unlocks performance-optimized tiers (db-perf-optimized-*) and data cache."
  type        = string
  default     = "ENTERPRISE"

  validation {
    condition     = contains(["ENTERPRISE", "ENTERPRISE_PLUS"], var.edition)
    error_message = "edition must be ENTERPRISE or ENTERPRISE_PLUS."
  }
}

# Storage
variable "storage_gb" {
  description = "Initial disk size in GB. Autoresize is always enabled; storage can only increase, never decrease."
  type        = number
  default     = 20

  validation {
    condition     = var.storage_gb >= 10
    error_message = "storage_gb must be at least 10."
  }
}

variable "disk_type" {
  description = "Storage type: PD_SSD (recommended) or PD_HDD"
  type        = string
  default     = "PD_SSD"

  validation {
    condition     = contains(["PD_SSD", "PD_HDD"], var.disk_type)
    error_message = "disk_type must be PD_SSD or PD_HDD."
  }
}

# High availability
variable "high_availability" {
  description = "Enable regional high availability with automatic failover to a standby in another zone"
  type        = bool
  default     = false
}

# Database credentials
variable "database_name" {
  description = "Name of the default database to create. Leave empty to skip."
  type        = string
  default     = null
}

variable "database_password" {
  description = "Password for the built-in postgres superuser. Minimum 8 characters."
  type        = string
  sensitive   = true
}

# Protection
variable "deletion_protection" {
  description = "Prevent accidental deletion of the database instance (applies at both Terraform and GCP API level)"
  type        = bool
  default     = true
}

# Backup
variable "backup_retention_count" {
  description = "Number of automated backups to retain"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_count >= 1 && var.backup_retention_count <= 365
    error_message = "backup_retention_count must be between 1 and 365."
  }
}

variable "point_in_time_recovery_enabled" {
  description = "Enable point-in-time recovery via WAL archiving. Enables recovery to any point within the transaction log retention window, but increases storage costs."
  type        = bool
  default     = true
}

# Network
variable "private_network" {
  description = "VPC network self_link for private IP access (e.g. google_compute_network.vpc.self_link). Requires Private Services Access peering to be configured on the VPC. Leave empty for public-only access."
  type        = string
  default     = null
}

variable "publicly_accessible" {
  description = "Assign a public IPv4 address to the instance"
  type        = bool
  default     = false
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to connect via public IP (authorized networks). Only applies when publicly_accessible is true."
  type        = list(string)
  default     = []
}

# Monitoring
variable "query_insights_enabled" {
  description = "Enable Query Insights for query-level performance monitoring"
  type        = bool
  default     = true
}

# Labels
variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
  default     = {}
}

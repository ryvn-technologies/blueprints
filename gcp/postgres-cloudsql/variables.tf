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

variable "managed_tag_value" {
  description = "Permanent ID of the tag value marking this instance as Ryvn-managed (e.g. tagValues/123456789012). The environment's agent role only has Cloud SQL write access on instances carrying it. Empty means the environment grants Cloud SQL write access project-wide and no tag is attached."
  type        = string
  default     = ""

  validation {
    condition     = var.managed_tag_value == "" || startswith(var.managed_tag_value, "tagValues/")
    error_message = "managed_tag_value must be a tag value permanent ID of the form tagValues/123456789012."
  }
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

variable "max_storage_gb" {
  description = "Maximum size in GB that Cloud SQL storage can automatically grow to. Set to 0 for no limit."
  type        = number
  default     = 0

  validation {
    condition     = var.max_storage_gb == 0 || var.max_storage_gb >= var.storage_gb
    error_message = "max_storage_gb must be 0 or greater than or equal to storage_gb."
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

variable "database_username" {
  description = "Password database username. Uses the built-in postgres user when set to postgres. A custom name creates an application user and requires database_password, even when IAM is enabled."
  type        = string
  default     = "postgres"

  validation {
    condition     = trimspace(var.database_username) != ""
    error_message = "database_username must not be empty."
  }
}

variable "database_password" {
  description = "Optional password for the built-in postgres user and any managed application user. Null requires IAM authentication and database_username set to postgres. Omitting a previously configured password does not guarantee revocation of existing postgres access."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.database_password == null ? true : length(var.database_password) > 0
    error_message = "database_password must be nonempty when provided. To omit password credentials, use null with IAM authentication enabled and database_username set to postgres."
  }
}

# IAM authentication
variable "iam_database_authentication_enabled" {
  description = "Enable Cloud SQL IAM database authentication. Password authentication also remains available when a password is supplied. Remove managed IAM database users and supply a password before disabling."
  type        = bool
  default     = false
  nullable    = false
}

variable "iam_database_users" {
  description = "Existing Google identities to register as database accounts, keyed by stable caller-defined labels. Supply full lowercase emails and CLOUD_IAM_USER, CLOUD_IAM_SERVICE_ACCOUNT, or CLOUD_IAM_GROUP. IAM bindings and SQL privileges are managed separately."
  type = map(object({
    email = string
    type  = string
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for user in var.iam_database_users : try(contains([
        "CLOUD_IAM_USER", "CLOUD_IAM_SERVICE_ACCOUNT", "CLOUD_IAM_GROUP",
      ], user.type), false)
    ])
    error_message = "Each IAM database user must specify CLOUD_IAM_USER, CLOUD_IAM_SERVICE_ACCOUNT, or CLOUD_IAM_GROUP. Cloud SQL manages group-member account types automatically."
  }

  validation {
    condition = alltrue([
      for user in var.iam_database_users : can(regex("^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$", user.email))
    ])
    error_message = "Each IAM database user must have a full lowercase email address without whitespace."
  }

  validation {
    condition = alltrue([
      for user in var.iam_database_users : try(
        (user.type == "CLOUD_IAM_SERVICE_ACCOUNT") == endswith(user.email, ".gserviceaccount.com"),
        false,
      )
    ])
    error_message = "Service accounts must use CLOUD_IAM_SERVICE_ACCOUNT and their full email ending in .gserviceaccount.com."
  }

  validation {
    condition = alltrue([
      for user in var.iam_database_users : try(length(user.type == "CLOUD_IAM_SERVICE_ACCOUNT" ? trimsuffix(user.email, ".gserviceaccount.com") : user.email) <= 63, false)
    ])
    error_message = "IAM SQL usernames must be at most 63 characters after removing the service-account .gserviceaccount.com suffix."
  }
}

# Encryption
variable "encryption_key_name" {
  description = "Cloud KMS key for CMEK disk encryption, as projects/PROJECT/locations/REGION/keyRings/RING/cryptoKeys/KEY. Leave empty for Google-managed encryption. The key must be in the instance's region and the Cloud SQL service agent (service-PROJECT_NUMBER@gcp-sa-cloud-sql.iam.gserviceaccount.com) needs roles/cloudkms.cryptoKeyEncrypterDecrypter on it before the instance is created. Cannot be changed after creation."
  type        = string
  default     = null

  validation {
    condition     = var.encryption_key_name == null || trimspace(var.encryption_key_name) == "" || can(regex("^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$", trimspace(var.encryption_key_name)))
    error_message = "encryption_key_name must be a Cloud KMS key resource name: projects/PROJECT/locations/REGION/keyRings/RING/cryptoKeys/KEY."
  }
}

# Protection
variable "deletion_protection" {
  description = "Prevent accidental deletion of the database instance (applies at both Terraform and GCP API level)"
  type        = bool
  default     = true
}

# Backup
variable "backup_retention_days" {
  description = "Number of days to retain automated backups. Set to 0 to disable automated backups entirely."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 0 && var.backup_retention_days <= 365
    error_message = "backup_retention_days must be between 0 and 365."
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

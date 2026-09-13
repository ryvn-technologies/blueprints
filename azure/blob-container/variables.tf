variable "location" {
  description = "Azure region for the storage account"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the storage account"
  type        = string
}

# Identity
variable "name_prefix" {
  description = "Fallback prefix for the storage account and container names when bucket_name is empty. A stable random suffix is appended automatically."
  type        = string
}

variable "bucket_name" {
  description = "Desired bucket (container) name, without the random suffix. If empty, name_prefix is used. Also seeds the storage account name after stripping non-alphanumerics."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name (e.g. production, staging)"
  type        = string
}

# Storage
variable "replication_type" {
  description = "Storage account replication type (LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS)"
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.replication_type)
    error_message = "replication_type must be one of LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

# Security
variable "versioning" {
  description = "Enable blob versioning."
  type        = bool
  default     = false
}

variable "public_access" {
  description = "Allow anonymous read access to blobs in the container. When false (default), the container is private and the account rejects public nested items. Not currently exposed by the bucket blueprint — left in place for direct module consumers and for a future cross-cloud publicAccess input."
  type        = bool
  default     = false
}

variable "shared_access_key_enabled" {
  description = "Allow storage account keys (and account-key SAS). Disabled by default so the only access path is Entra ID / RBAC; user-delegation SAS still works for presigned URLs."
  type        = bool
  default     = false
}

variable "public_network_access" {
  description = "Allow access to the storage account over public endpoints. Workloads currently reach storage over public IPs; set to false only when private endpoints are configured out of band."
  type        = bool
  default     = true
}

variable "cors_rules" {
  description = "Browser CORS rules for direct cross-origin blob requests, applied to the storage account's blob service."
  type = list(object({
    allowed_origins = list(string)
    allowed_methods = list(string)
    allowed_headers = list(string)
    expose_headers  = list(string)
    max_age_seconds = number
  }))
  default = []

  validation {
    condition = alltrue([
      for rule in var.cors_rules :
      length(rule.allowed_origins) > 0
    ])
    error_message = "Each CORS rule must contain at least one allowed origin."
  }

  validation {
    condition = alltrue([
      for rule in var.cors_rules :
      length(rule.allowed_methods) > 0
    ])
    error_message = "Each CORS rule must contain at least one allowed method."
  }

  validation {
    condition = alltrue(flatten([
      for rule in var.cors_rules : [
        for method in rule.allowed_methods :
        contains(["DELETE", "GET", "HEAD", "MERGE", "POST", "OPTIONS", "PUT", "PATCH"], upper(trimspace(method)))
      ]
    ]))
    error_message = "CORS rule methods must only contain valid Azure Blob CORS methods: DELETE, GET, HEAD, MERGE, POST, OPTIONS, PUT, PATCH."
  }

  validation {
    condition = alltrue([
      for rule in var.cors_rules :
      rule.max_age_seconds >= 0
    ])
    error_message = "Each CORS rule max_age_seconds value must be 0 or greater."
  }

  validation {
    condition     = length(var.cors_rules) <= 5
    error_message = "Azure Blob storage supports at most 5 CORS rules."
  }
}

# Lifecycle
variable "expiration_days" {
  description = "Delete current-version blobs this many days after last modification. Set to 0 to disable."
  type        = number
  default     = 0

  validation {
    condition     = var.expiration_days >= 0
    error_message = "expiration_days must be 0 or greater."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Delete previous blob versions this many days after they were created. Only applies when versioning is enabled. Set to 0 to disable."
  type        = number
  default     = 0

  validation {
    condition     = var.noncurrent_version_expiration_days >= 0
    error_message = "noncurrent_version_expiration_days must be 0 or greater."
  }
}

# Protection
variable "deletion_protection" {
  description = "Place a CanNotDelete management lock on the storage account. This blocks out-of-band deletes (portal, CLI, other tooling) but not a Terraform destroy of this module, which removes the lock first; unlike force_destroy on AWS/GCP it does not fail on a non-empty container."
  type        = bool
  default     = true
}

# Encryption
variable "encryption_key_id" {
  description = "Azure Resource Manager ID of a Key Vault key (/subscriptions/<s>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<v>/keys/<k>) used as the storage account's customer-managed key. Leave empty for Microsoft-managed keys. The vault must use RBAC authorization with soft delete and purge protection enabled; the account's system-assigned identity is granted Key Vault Crypto Service Encryption User on the vault. The versionless key is bound so rotation is picked up automatically."
  type        = string
  default     = ""

  validation {
    condition     = var.encryption_key_id == "" || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.KeyVault/vaults/[^/]+/keys/[^/]+$", var.encryption_key_id))
    error_message = "encryption_key_id must be empty or a Key Vault key resource ID (/subscriptions/<s>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<v>/keys/<k>)."
  }
}

# Tags
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

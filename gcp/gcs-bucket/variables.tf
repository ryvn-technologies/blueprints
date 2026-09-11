variable "project_id" {
  description = "GCP project that owns the bucket"
  type        = string
}

variable "region" {
  description = "GCP region (bucket location)"
  type        = string
  default     = "us-central1"
}

# Identity
variable "name_prefix" {
  description = "Fallback prefix for the bucket name when bucket_name is empty. A stable random suffix is appended automatically."
  type        = string
}

variable "bucket_name" {
  description = "Desired bucket name (without the random suffix). If empty, name_prefix is used."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name (e.g. production, staging)"
  type        = string
}

# Security
variable "versioning" {
  description = "Enable object versioning."
  type        = bool
  default     = false
}

variable "public_access" {
  description = "Allow public access to the bucket. When false (default), public access prevention is enforced. Not currently exposed by the bucket blueprint — left in place for direct module consumers and for a future cross-cloud publicAccess input."
  type        = bool
  default     = false
}

variable "cors_rules" {
  description = "Browser CORS rules for direct cross-origin bucket requests. GCS merges allowed_headers and expose_headers into a single response header list."
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
        contains(["GET", "PUT", "POST", "DELETE", "HEAD", "OPTIONS", "*"], upper(trimspace(method)))
      ]
    ]))
    error_message = "CORS rule methods must only contain valid GCS CORS methods: GET, PUT, POST, DELETE, HEAD, OPTIONS, *."
  }

  validation {
    condition = alltrue([
      for rule in var.cors_rules :
      rule.max_age_seconds >= 0
    ])
    error_message = "Each CORS rule max_age_seconds value must be 0 or greater."
  }
}

# Lifecycle
variable "expiration_days" {
  description = "Delete current-version objects after this many days. Set to 0 to disable."
  type        = number
  default     = 0

  validation {
    condition     = var.expiration_days >= 0
    error_message = "expiration_days must be 0 or greater."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Delete noncurrent object versions after this many days. Only applies when versioning is enabled. Set to 0 to disable."
  type        = number
  default     = 0

  validation {
    condition     = var.noncurrent_version_expiration_days >= 0
    error_message = "noncurrent_version_expiration_days must be 0 or greater."
  }
}

# Protection
variable "deletion_protection" {
  description = "Prevent Terraform from deleting the bucket. When true, the bucket cannot be destroyed while it contains objects. When false, Terraform empties the bucket (including all versions) before deletion."
  type        = bool
  default     = true
}

# Encryption
variable "kms_key_name" {
  description = "Full resource name of a Cloud KMS key (projects/<p>/locations/<l>/keyRings/<r>/cryptoKeys/<k>) used as the bucket's default encryption key. Leave empty for Google-managed keys. The key must be in the bucket's location; the storage service agent is granted cryptoKeyEncrypterDecrypter on it."
  type        = string
  default     = ""

  validation {
    condition     = var.kms_key_name == "" || can(regex("^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$", var.kms_key_name))
    error_message = "kms_key_name must be empty or of the form projects/<p>/locations/<l>/keyRings/<r>/cryptoKeys/<k>."
  }
}

# Labels
variable "labels" {
  description = "Labels to apply to the bucket"
  type        = map(string)
  default     = {}
}

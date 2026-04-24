variable "aws_region" {
  description = "AWS region where the bucket is created"
  type        = string
  default     = "us-east-1"
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
  description = "Enable object versioning. Once enabled, versioning can be suspended but not fully removed."
  type        = bool
  default     = false
}

variable "public_access" {
  description = "Allow public access to the bucket. When false (default), all four S3 public access block settings are enforced. Not currently exposed by the bucket blueprint — left in place for direct module consumers and for a future cross-cloud publicAccess input."
  type        = bool
  default     = false
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

# Pod Identity
variable "cluster_name" {
  description = "Name of the EKS cluster where Pod Identity associations will be created"
  type        = string
}

variable "pod_identity_namespace" {
  description = "Kubernetes namespace containing the service accounts that should assume the bucket access role via EKS Pod Identity. Leave empty to create only the role."
  type        = string
  default     = ""
}

variable "pod_identity_service_accounts" {
  description = "Kubernetes service account names in pod_identity_namespace that should assume the bucket access role via EKS Pod Identity. Leave empty to create only the role."
  type        = list(string)
  default     = []
}

# Tags
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

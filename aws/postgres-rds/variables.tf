variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
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
variable "engine_version" {
  description = "PostgreSQL engine version (major or major.minor)"
  type        = string
  default     = "16"

  validation {
    condition     = can(regex("^(17|16|15|14|13)(\\.\\d+)?$", var.engine_version))
    error_message = "Supported PostgreSQL versions are 13-17, optionally with minor version (e.g. 16.4)."
  }
}

# Compute
variable "instance_class" {
  description = "Instance class for the RDS instance"
  type        = string
  default     = "db.t3.medium"
}

# Storage
variable "storage_gb" {
  description = "Allocated storage in GiB. Can only be increased, never decreased."
  type        = number
  default     = 20
}

variable "max_storage_gb" {
  description = "Maximum storage for autoscaling in GiB. Set to 0 to disable."
  type        = number
  default     = 100
}

# High availability
variable "high_availability" {
  description = "Enable multi-AZ deployment for high availability"
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
  description = "Master username. Cannot be changed after creation."
  type        = string
}

variable "database_password" {
  description = "Master password. Minimum 8 characters."
  type        = string
  sensitive   = true
}

# Protection
variable "deletion_protection" {
  description = "Prevent accidental deletion of the database instance"
  type        = bool
  default     = true
}

# Backup
variable "backup_retention_days" {
  description = "Number of days to retain automated backups"
  type        = number
  default     = 7
}

# Network
variable "vpc_id" {
  description = "VPC ID where the database will be created"
  type        = string
}

variable "subnet_ids" {
  description = "Comma-separated list of subnet IDs for the database subnet group"
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the database"
  type        = list(string)
  default     = []
}

variable "publicly_accessible" {
  description = "Whether the database should be publicly accessible"
  type        = bool
  default     = false
}

# Monitoring
variable "performance_insights_enabled" {
  description = "Enable Performance Insights for query-level monitoring"
  type        = bool
  default     = true
}

variable "performance_insights_retention_period" {
  description = "Retention period for Performance Insights data in days. Free tier is 7 days; valid values are 7, 31, 62, 93, 186, 372, 731."
  type        = number
  default     = 7
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds. Set to 0 to disable. Valid values: 0, 1, 5, 10, 15, 30, 60."
  type        = number
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of: 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "enabled_cloudwatch_logs_exports" {
  description = "List of log types to export to CloudWatch. Valid values: postgresql, upgrade."
  type        = list(string)
  default     = ["postgresql", "upgrade"]
}

# Tags
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

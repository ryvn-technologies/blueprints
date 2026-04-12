variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# Naming
variable "installation_name" {
  description = "Prefix for the ElastiCache replication group name. A stable random suffix is appended automatically."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., production, staging)"
  type        = string
}

# Engine Configuration
variable "engine" {
  description = "Cache engine to use: 'redis' or 'valkey'"
  type        = string
  default     = "redis"

  validation {
    condition     = contains(["redis", "valkey"], var.engine)
    error_message = "Engine must be either 'redis' or 'valkey'."
  }
}

variable "engine_version" {
  description = "Engine version. For Redis: e.g. '7.1'. For Valkey: e.g. '7.2'. If null, uses the latest default for the selected engine."
  type        = string
  default     = null
}

variable "parameter_group_name" {
  description = "Name of the parameter group to use. If null, uses the default for the selected engine and version."
  type        = string
  default     = null
}

# Network Configuration
variable "vpc_id" {
  description = "VPC ID where ElastiCache will be created. Cannot be changed after creation."
  type        = string
}

variable "private_subnet_ids" {
  description = "Comma-separated list of private subnet IDs for the cache subnet group"
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the cache cluster (port 6379). Added in addition to the VPC CIDR."
  type        = list(string)
  default     = []
}

# Instance Configuration
variable "node_type" {
  description = "ElastiCache node type (e.g., cache.t3.medium, cache.r7g.large)"
  type        = string
  default     = "cache.t3.medium"
}

variable "num_cache_clusters" {
  description = "Number of cache clusters (nodes) in the replication group. Set to >1 for read replicas."
  type        = number
  default     = 1

  validation {
    condition     = var.num_cache_clusters >= 1 && var.num_cache_clusters <= 6
    error_message = "num_cache_clusters must be between 1 and 6."
  }
}

variable "port" {
  description = "Port number for the cache"
  type        = number
  default     = 6379
}

# High Availability
variable "multi_az_enabled" {
  description = "Enable Multi-AZ with automatic failover. Requires num_cache_clusters >= 2."
  type        = bool
  default     = false
}

variable "automatic_failover_enabled" {
  description = "Enable automatic failover. Requires num_cache_clusters >= 2."
  type        = bool
  default     = false
}

# Encryption
variable "at_rest_encryption_enabled" {
  description = "Enable encryption at rest. Cannot be changed after creation."
  type        = bool
  default     = true
}

variable "transit_encryption_enabled" {
  description = "Enable in-transit encryption (TLS). Clients must support TLS when enabled."
  type        = bool
  default     = true
}

# Authentication
variable "auth_token" {
  description = "Auth token (password) for Redis/Valkey AUTH. If null and transit_encryption_enabled is true, a token is auto-generated. Must be 16-128 chars if provided manually."
  type        = string
  default     = null
  sensitive   = true
}

# Maintenance
variable "maintenance_window" {
  description = "Weekly maintenance window (e.g., 'sun:04:00-sun:05:00')"
  type        = string
  default     = "sun:04:00-sun:05:00"
}

variable "snapshot_retention_limit" {
  description = "Number of days to retain automatic snapshots. Set to 0 to disable."
  type        = number
  default     = 7
}

variable "snapshot_window" {
  description = "Daily time range for automatic snapshots (e.g., '03:00-04:00')"
  type        = string
  default     = "03:00-04:00"
}

# Logging
variable "slow_log_enabled" {
  description = "Enable slow log delivery to CloudWatch Logs. Useful for identifying slow commands."
  type        = bool
  default     = true
}

variable "engine_log_enabled" {
  description = "Enable engine log delivery to CloudWatch Logs. Captures internal engine events."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention period in days for CloudWatch log groups. Valid values: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  type        = number
  default     = 7
}

# Notifications
variable "notification_topic_arn" {
  description = "ARN of an SNS topic for ElastiCache notifications"
  type        = string
  default     = null
}

# Tags
variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default = {
    Terraform = "true"
  }
}

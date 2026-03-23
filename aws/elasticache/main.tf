terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0.0"

  backend "kubernetes" {}
}

provider "aws" {
  region = var.aws_region
}

locals {
  # Resolve engine version and parameter group defaults
  default_engine_versions = {
    redis  = "7.1"
    valkey = "7.2"
  }
  engine_version = coalesce(var.engine_version, local.default_engine_versions[var.engine])

  # Extract major version for default parameter group
  major_version = split(".", local.engine_version)[0]
  default_parameter_groups = {
    redis  = "default.redis${local.major_version}"
    valkey = "default.valkey${local.major_version}"
  }
  parameter_group_name = coalesce(var.parameter_group_name, local.default_parameter_groups[var.engine])

  # Auto-generate auth token when TLS is enabled and no token is provided
  auth_token = var.transit_encryption_enabled ? (
    var.auth_token != null ? var.auth_token : random_password.auth_token[0].result
  ) : var.auth_token
}

resource "random_password" "auth_token" {
  count   = var.transit_encryption_enabled && var.auth_token == null ? 1 : 0
  length  = 64
  special = false
}

resource "aws_cloudwatch_log_group" "slow_log" {
  count             = var.slow_log_enabled ? 1 : 0
  name              = "/elasticache/${var.installation_name}/slow-log"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "engine_log" {
  count             = var.engine_log_enabled ? 1 : 0
  name              = "/elasticache/${var.installation_name}/engine-log"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.installation_name
  description          = "${var.engine} cluster for ${var.environment}"

  # Engine
  engine               = var.engine
  engine_version       = local.engine_version
  node_type            = var.node_type
  num_cache_clusters   = var.num_cache_clusters
  parameter_group_name = local.parameter_group_name
  port                 = var.port

  # Network
  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.cache.id]

  # High Availability
  multi_az_enabled           = var.multi_az_enabled
  automatic_failover_enabled = var.automatic_failover_enabled

  # Encryption
  at_rest_encryption_enabled = var.at_rest_encryption_enabled
  transit_encryption_enabled = var.transit_encryption_enabled

  # Authentication
  auth_token = local.auth_token

  # Maintenance & Snapshots
  maintenance_window       = var.maintenance_window
  snapshot_retention_limit = var.snapshot_retention_limit
  snapshot_window          = var.snapshot_window
  notification_topic_arn   = var.notification_topic_arn

  # Logging
  dynamic "log_delivery_configuration" {
    for_each = var.slow_log_enabled ? [1] : []
    content {
      destination      = aws_cloudwatch_log_group.slow_log[0].name
      destination_type = "cloudwatch-logs"
      log_format       = "json"
      log_type         = "slow-log"
    }
  }

  dynamic "log_delivery_configuration" {
    for_each = var.engine_log_enabled ? [1] : []
    content {
      destination      = aws_cloudwatch_log_group.engine_log[0].name
      destination_type = "cloudwatch-logs"
      log_format       = "json"
      log_type         = "engine-log"
    }
  }

  # Apply changes immediately in non-maintenance windows
  apply_immediately = true

  tags = merge(var.tags, {
    "ryvn.app/environment" = var.environment
  })

  lifecycle {
    precondition {
      condition     = !var.multi_az_enabled || var.num_cache_clusters >= 2
      error_message = "multi_az_enabled requires num_cache_clusters >= 2."
    }
    precondition {
      condition     = !var.automatic_failover_enabled || var.num_cache_clusters >= 2
      error_message = "automatic_failover_enabled requires num_cache_clusters >= 2."
    }
    precondition {
      condition     = var.auth_token == null || var.transit_encryption_enabled
      error_message = "auth_token requires transit_encryption_enabled = true."
    }
    precondition {
      condition     = !var.transit_encryption_enabled || local.auth_token != null
      error_message = "transit_encryption_enabled requires authentication. Provide auth_token or leave it null to auto-generate one."
    }
  }
}

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

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name          = "${var.name_prefix}-${random_id.suffix.hex}"
  major_version = split(".", var.engine_version)[0]
  family        = "postgres${local.major_version}"

  all_tags = merge(var.tags, {
    Terraform               = "true"
    "ryvn.app/environment"  = var.environment
  })
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${local.name}-"
  family      = local.family
  description = "Parameter group for ${local.name}"

  parameter {
    name  = "autovacuum"
    value = "1"
  }

  parameter {
    name  = "client_encoding"
    value = "utf8"
  }

  tags = local.all_tags

  lifecycle {
    create_before_destroy = true
  }
}
resource "aws_db_instance" "this" {
  identifier = local.name

  # Engine
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # Storage
  allocated_storage     = var.storage_gb
  max_allocated_storage = var.max_storage_gb > 0 ? var.max_storage_gb : null
  storage_type          = "gp3"
  storage_encrypted     = true

  # Database
  db_name  = var.database_name
  username = var.database_username
  password = var.database_password
  port     = 5432

  # Network
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = var.high_availability
  publicly_accessible    = var.publicly_accessible

  # Parameter group
  parameter_group_name = aws_db_parameter_group.this.name

  # Protection
  deletion_protection = var.deletion_protection

  # Backup
  backup_retention_period = var.backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"
  skip_final_snapshot          = false
  final_snapshot_identifier    = "${local.name}-final"
  copy_tags_to_snapshot        = true

  # Monitoring
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring[0].arn : null
  enabled_cloudwatch_logs_exports       = var.enabled_cloudwatch_logs_exports

  tags = local.all_tags
}

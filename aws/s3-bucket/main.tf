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
  base_name   = coalesce(var.bucket_name, var.name_prefix)
  bucket_name = "${local.base_name}-${random_id.suffix.hex}"

  all_tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment
  })

  has_expiration            = var.expiration_days > 0
  has_noncurrent_expiration = var.versioning && var.noncurrent_version_expiration_days > 0
  has_lifecycle_rules       = local.has_expiration || local.has_noncurrent_expiration
}

resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name

  force_destroy = !var.deletion_protection

  tags = local.all_tags
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = !var.public_access
  block_public_policy     = !var.public_access
  ignore_public_acls      = !var.public_access
  restrict_public_buckets = !var.public_access
}

resource "aws_s3_bucket_cors_configuration" "this" {
  count = length(var.cors_rules) > 0 ? 1 : 0

  bucket = aws_s3_bucket.this.id

  dynamic "cors_rule" {
    for_each = var.cors_rules
    content {
      allowed_headers = cors_rule.value.allowed_headers
      allowed_methods = [
        for method in cors_rule.value.allowed_methods :
        upper(trimspace(method))
      ]
      allowed_origins = cors_rule.value.allowed_origins
      expose_headers  = cors_rule.value.expose_headers
      max_age_seconds = cors_rule.value.max_age_seconds
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count = local.has_lifecycle_rules ? 1 : 0

  bucket = aws_s3_bucket.this.id

  depends_on = [aws_s3_bucket_versioning.this]

  dynamic "rule" {
    for_each = local.has_expiration ? [1] : []
    content {
      id     = "expire-current-versions"
      status = "Enabled"

      filter {}

      expiration {
        days = var.expiration_days
      }
    }
  }

  dynamic "rule" {
    for_each = local.has_noncurrent_expiration ? [1] : []
    content {
      id     = "expire-noncurrent-versions"
      status = "Enabled"

      filter {}

      noncurrent_version_expiration {
        noncurrent_days = var.noncurrent_version_expiration_days
      }
    }
  }
}

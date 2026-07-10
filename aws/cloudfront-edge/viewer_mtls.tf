resource "aws_s3_bucket" "viewer_mtls_ca_bundle" {
  for_each = local.create_viewer_mtls_managed_ca_s3 ? { this = true } : {}

  provider = aws.us_east_1

  bucket_prefix = local.viewer_mtls_bucket_name_prefix
  force_destroy = true

  tags = merge(var.tags, {
    Name = "${local.resource_name}-viewer-mtls-ca"
  })
}

resource "aws_s3_bucket_public_access_block" "viewer_mtls_ca_bundle" {
  for_each = aws_s3_bucket.viewer_mtls_ca_bundle

  provider = aws.us_east_1

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "viewer_mtls_ca_bundle" {
  for_each = aws_s3_bucket.viewer_mtls_ca_bundle

  provider = aws.us_east_1

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "viewer_mtls_ca_bundle" {
  for_each = aws_s3_bucket.viewer_mtls_ca_bundle

  provider = aws.us_east_1

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "viewer_mtls_ca_bundle" {
  for_each = local.create_viewer_mtls_managed_ca_s3 ? { this = true } : {}

  provider = aws.us_east_1

  bucket       = aws_s3_bucket.viewer_mtls_ca_bundle["this"].id
  key          = local.viewer_mtls_ca_bundle_s3_key
  content      = local.viewer_mtls_ca_bundle_pem
  content_type = "application/x-pem-file"
  source_hash  = nonsensitive(sha256(local.viewer_mtls_ca_bundle_pem))

  tags = var.tags

  depends_on = [
    aws_s3_bucket_public_access_block.viewer_mtls_ca_bundle,
    aws_s3_bucket_server_side_encryption_configuration.viewer_mtls_ca_bundle,
    aws_s3_bucket_versioning.viewer_mtls_ca_bundle,
  ]
}

resource "aws_cloudfront_trust_store" "viewer_mtls" {
  for_each = local.create_viewer_mtls_trust_store ? { this = var.viewer_mtls.trust_store } : {}

  provider = aws.us_east_1

  name = local.viewer_mtls_trust_store_name

  ca_certificates_bundle_source {
    ca_certificates_bundle_s3_location {
      bucket  = local.viewer_mtls_ca_bundle_s3_bucket
      key     = local.viewer_mtls_ca_bundle_s3_key
      region  = local.viewer_mtls_ca_bundle_s3_region
      version = local.viewer_mtls_ca_bundle_s3_version
    }
  }

  dynamic "timeouts" {
    for_each = each.value.timeouts != null ? [each.value.timeouts] : []

    content {
      create = timeouts.value.create
      delete = timeouts.value.delete
      update = timeouts.value.update
    }
  }

  tags = merge(var.tags, each.value.tags)
}

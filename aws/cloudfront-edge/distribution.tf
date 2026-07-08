resource "aws_cloudfront_distribution" "this" {
  provider = aws.us_east_1

  aliases             = local.hostname_keys
  comment             = local.distribution_comment
  enabled             = var.enabled
  http_version        = var.http_version
  is_ipv6_enabled     = var.ipv6_enabled
  price_class         = var.price_class
  retain_on_delete    = var.retain_on_delete
  wait_for_deployment = var.wait_for_deployment
  web_acl_id          = local.web_acl_arn
  tags                = var.tags

  dynamic "custom_error_response" {
    for_each = var.custom_error_responses

    content {
      error_caching_min_ttl = custom_error_response.value.error_caching_min_ttl
      error_code            = custom_error_response.value.error_code
      response_code         = custom_error_response.value.response_code
      response_page_path    = custom_error_response.value.response_page_path
    }
  }

  origin {
    connection_attempts = var.connection_attempts
    connection_timeout  = var.connection_timeout
    domain_name         = local.origin_hostname
    origin_id           = local.origin_id

    dynamic "custom_origin_config" {
      for_each = local.origin_is_public ? [1] : []

      content {
        http_port                = 80
        https_port               = var.origin_port
        origin_keepalive_timeout = var.origin_keepalive_timeout
        origin_protocol_policy   = "https-only"
        origin_read_timeout      = var.origin_read_timeout
        origin_ssl_protocols     = var.origin_ssl_protocols

        origin_mtls_config {
          client_certificate_arn = local.origin_client_certificate_arn
        }
      }
    }

    dynamic "vpc_origin_config" {
      for_each = local.origin_is_internal ? [1] : []

      content {
        origin_keepalive_timeout = var.vpc_origin.origin_keepalive_timeout
        origin_read_timeout      = var.vpc_origin.origin_read_timeout
        vpc_origin_id            = local.vpc_origin_id
      }
    }

    dynamic "origin_shield" {
      for_each = var.origin_shield.enabled ? [var.origin_shield] : []

      content {
        enabled              = origin_shield.value.enabled
        origin_shield_region = origin_shield.value.origin_shield_region
      }
    }
  }

  default_cache_behavior {
    allowed_methods            = var.allowed_methods
    cache_policy_id            = local.cache_policy_id
    cached_methods             = var.cached_methods
    compress                   = var.compress
    origin_request_policy_id   = local.origin_request_policy_id
    response_headers_policy_id = local.response_headers_policy_id
    target_origin_id           = local.origin_id
    viewer_protocol_policy     = "redirect-to-https"
  }

  dynamic "viewer_mtls_config" {
    for_each = var.viewer_mtls.enabled ? [var.viewer_mtls] : []

    content {
      mode = viewer_mtls_config.value.mode

      trust_store_config {
        advertise_trust_store_ca_names = viewer_mtls_config.value.advertise_trust_store_ca_names
        ignore_certificate_expiry      = viewer_mtls_config.value.ignore_certificate_expiry
        trust_store_id                 = local.viewer_mtls_trust_store_id
      }
    }
  }

  restrictions {
    geo_restriction {
      locations        = var.geo_restriction.locations
      restriction_type = var.geo_restriction.restriction_type
    }
  }

  viewer_certificate {
    acm_certificate_arn      = local.viewer_certificate_arn
    minimum_protocol_version = var.minimum_protocol_version
    ssl_support_method       = "sni-only"
  }
}

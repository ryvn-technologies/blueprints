output "distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "CloudFront distribution ARN."
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "CloudFront DNS name."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_hosted_zone_id" {
  description = "CloudFront hosted zone ID for Route53 alias records."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "aliases" {
  description = "CloudFront aliases configured by this module."
  value       = local.hostname_keys
}

output "origin_type" {
  description = "Origin mode used by this distribution."
  value       = local.origin_mode
}

output "origin_hostname" {
  description = "Effective Ryvn origin hostname CloudFront forwards requests to."
  value       = local.origin_hostname
}

output "vpc_origin_id" {
  description = "CloudFront VPC origin ID used when origin_type = internal or vpc."
  value       = local.origin_is_internal ? local.vpc_origin_id : null
}

output "web_acl_arn" {
  description = "AWS WAFv2 WebACL ARN attached to the CloudFront distribution, when configured."
  value       = local.web_acl_arn
}

output "waf" {
  description = "Created AWS WAFv2 WebACL and IP set details when this module creates a WebACL."
  value = {
    created                  = local.create_waf
    arn                      = try(module.waf[0].aws_wafv2_arn, null)
    id                       = try(module.waf[0].aws_wafv2_id, null)
    name                     = try(module.waf[0].aws_wafv2_name, null)
    capacity                 = try(module.waf[0].aws_wafv2_capacity, null)
    logging_configuration_id = try(module.waf[0].aws_wafv2_web_acl_logging_configuration_id, null)
    ip_sets = {
      for key, ip_set in module.waf_ip_set : key => {
        arn      = ip_set.aws_wafv2_ip_set_arn
        id       = ip_set.aws_wafv2_ip_set_id
        tags_all = ip_set.aws_wafv2_ip_set_tags_all
      }
    }
  }
}

output "viewer_certificate_arn" {
  description = "ACM viewer certificate ARN used by CloudFront."
  value       = local.viewer_certificate_arn
}

output "viewer_mtls" {
  description = "Viewer mTLS configuration and trust store identifiers, when enabled."
  value = {
    enabled                   = var.viewer_mtls.enabled
    mode                      = var.viewer_mtls.enabled ? var.viewer_mtls.mode : null
    trust_store_id            = var.viewer_mtls.enabled ? local.viewer_mtls_trust_store_id : null
    trust_store_arn           = try(aws_cloudfront_trust_store.viewer_mtls["this"].arn, null)
    trust_store_etag          = try(aws_cloudfront_trust_store.viewer_mtls["this"].etag, null)
    number_of_ca_certificates = try(aws_cloudfront_trust_store.viewer_mtls["this"].number_of_ca_certificates, null)
    ca_bundle_s3_bucket       = var.viewer_mtls.enabled ? local.viewer_mtls_ca_bundle_s3_bucket : null
    ca_bundle_s3_key          = var.viewer_mtls.enabled ? local.viewer_mtls_ca_bundle_s3_key : null
    ca_bundle_s3_region       = var.viewer_mtls.enabled ? local.viewer_mtls_ca_bundle_s3_region : null
    ca_bundle_s3_version      = var.viewer_mtls.enabled ? local.viewer_mtls_ca_bundle_s3_version : null
  }
}

output "origin_client_certificate_arn" {
  description = "ACM client certificate ARN CloudFront presents to the Ryvn origin when origin_type = public."
  value       = local.origin_client_certificate_arn
}

output "monitoring_subscription_id" {
  description = "CloudFront monitoring subscription ID, when enabled."
  value       = try(aws_cloudfront_monitoring_subscription.this[0].id, null)
}

output "standard_logging_v2" {
  description = "CloudFront standard logging v2 resources, when enabled."
  value = {
    source_name     = try(aws_cloudwatch_log_delivery_source.cloudfront[0].name, null)
    destination_arn = try(aws_cloudwatch_log_delivery_destination.cloudfront[0].arn, null)
    delivery_id     = try(aws_cloudwatch_log_delivery.cloudfront[0].id, null)
  }
}

output "required_dns_records" {
  description = "CNAME records to create outside Terraform-managed Route53."
  value       = local.required_dns_records
}

output "route53_records" {
  description = "Route53 alias records managed by this module, keyed by hostname and type."
  value = {
    a = {
      for hostname, record in aws_route53_record.a : hostname => {
        id   = record.id
        fqdn = record.fqdn
        type = record.type
      }
    }
    aaaa = {
      for hostname, record in aws_route53_record.aaaa : hostname => {
        id   = record.id
        fqdn = record.fqdn
        type = record.type
      }
    }
  }
}

locals {
  managed_public_dns_root = trimsuffix(trimspace(var.managed_public_dns_root), ".")
  managed_private_dns_root = (
    trimspace(var.managed_private_dns_root) == "" ?
    "" :
    trimsuffix(trimspace(var.managed_private_dns_root), ".")
  )

  default_hostname_keys = [
    local.managed_public_dns_root,
    "*.${local.managed_public_dns_root}",
  ]
  hostname_keys = sort(tolist(length(var.hostnames) > 0 ? var.hostnames : toset(local.default_hostname_keys)))

  origin_mode        = var.origin_type == "vpc" ? "internal" : var.origin_type
  origin_is_public   = local.origin_mode == "public"
  origin_is_internal = local.origin_mode == "internal"

  public_origin_hostname = (
    trimspace(var.origin_hostname) != "" ?
    trimspace(var.origin_hostname) :
    "origin.${local.managed_public_dns_root}"
  )
  internal_origin_hostname = (
    trimspace(var.vpc_origin.domain_name) != "" ?
    trimspace(var.vpc_origin.domain_name) :
    "internal-origin.${local.managed_private_dns_root}"
  )
  origin_hostname = (
    local.origin_is_internal ?
    local.internal_origin_hostname :
    local.public_origin_hostname
  )
  origin_id = "ryvn-${local.origin_mode}-origin-${substr(sha1(local.origin_hostname), 0, 12)}"
  origin_client_certificate_arn = (
    local.origin_is_public ?
    trimspace(var.origin_client_certificate_arn) :
    null
  )
  create_vpc_origin = local.origin_is_internal && var.vpc_origin.create
  lookup_vpc_origin_endpoint = (
    local.create_vpc_origin &&
    trimspace(var.vpc_origin.endpoint_arn) == "" &&
    length(var.vpc_origin.endpoint_lookup_tags) > 0
  )
  vpc_origin_endpoint_arn = (
    trimspace(var.vpc_origin.endpoint_arn) != "" ?
    trimspace(var.vpc_origin.endpoint_arn) :
    try(data.aws_lb.vpc_origin_endpoint["this"].arn, "")
  )
  vpc_origin_id = (
    local.create_vpc_origin ?
    aws_cloudfront_vpc_origin.this["this"].id :
    trimspace(var.vpc_origin.existing_vpc_origin_id)
  )

  use_managed_viewer_certificate       = trimspace(var.viewer_certificate_arn) == ""
  lookup_public_route53_zone           = local.use_managed_viewer_certificate || var.dns.enabled
  viewer_certificate_wildcard_hostname = "*.${local.managed_public_dns_root}"
  viewer_certificate_hostnames = (
    length(var.hostnames) > 0 ?
    local.hostname_keys :
    [local.managed_public_dns_root, local.viewer_certificate_wildcard_hostname]
  )
  viewer_certificate_primary_hostname = local.viewer_certificate_hostnames[0]
  viewer_certificate_sans             = slice(local.viewer_certificate_hostnames, 1, length(local.viewer_certificate_hostnames))
  viewer_certificate_validation_domains = toset([
    for hostname in local.viewer_certificate_hostnames : hostname
    if !startswith(hostname, "*.") || !contains(local.viewer_certificate_hostnames, trimprefix(hostname, "*."))
  ])
  viewer_certificate_arn = (
    local.use_managed_viewer_certificate ?
    aws_acm_certificate_validation.viewer[0].certificate_arn :
    trimspace(var.viewer_certificate_arn)
  )
  create_viewer_mtls_trust_store   = var.viewer_mtls.enabled && var.viewer_mtls.trust_store.create
  viewer_mtls_trust_store_name     = trimspace(var.viewer_mtls.trust_store.name) != "" ? trimspace(var.viewer_mtls.trust_store.name) : "${local.short_resource_name}-viewer-mtls"
  viewer_mtls_ca_bundle_pem        = trimspace(var.viewer_mtls_ca_bundle_pem)
  viewer_mtls_has_ca_bundle_pem    = nonsensitive(local.viewer_mtls_ca_bundle_pem != "")
  create_viewer_mtls_managed_ca_s3 = local.create_viewer_mtls_trust_store && local.viewer_mtls_has_ca_bundle_pem
  viewer_mtls_ca_bundle_s3_key     = local.create_viewer_mtls_managed_ca_s3 ? "viewer-mtls/ca-bundle.pem" : trimspace(var.viewer_mtls.trust_store.ca_bundle_s3.key)
  viewer_mtls_ca_bundle_s3_bucket  = local.create_viewer_mtls_managed_ca_s3 ? aws_s3_bucket.viewer_mtls_ca_bundle["this"].id : trimspace(var.viewer_mtls.trust_store.ca_bundle_s3.bucket)
  viewer_mtls_ca_bundle_s3_region  = local.create_viewer_mtls_managed_ca_s3 ? "us-east-1" : trimspace(var.viewer_mtls.trust_store.ca_bundle_s3.region)
  viewer_mtls_ca_bundle_s3_version = local.create_viewer_mtls_managed_ca_s3 ? aws_s3_object.viewer_mtls_ca_bundle["this"].version_id : trimspace(var.viewer_mtls.trust_store.ca_bundle_s3.version) != "" ? trimspace(var.viewer_mtls.trust_store.ca_bundle_s3.version) : null
  viewer_mtls_trust_store_id = (
    local.create_viewer_mtls_trust_store ?
    aws_cloudfront_trust_store.viewer_mtls["this"].id :
    trimspace(var.viewer_mtls.existing_trust_store_id)
  )

  use_managed_cache_policy = var.cache_policy_id == ""
  cache_policy_name        = trimspace(var.cache_policy_name)
  cache_policy_id = (
    local.use_managed_cache_policy ?
    data.aws_cloudfront_cache_policy.this[0].id :
    trimspace(var.cache_policy_id)
  )

  default_origin_request_policy_name = (
    var.preserve_viewer_host_header ?
    "Managed-AllViewer" :
    "Managed-AllViewerExceptHostHeader"
  )
  use_managed_origin_request_policy = var.origin_request_policy_id == ""
  origin_request_policy_name = (
    trimspace(var.origin_request_policy_name) != "" ?
    trimspace(var.origin_request_policy_name) :
    local.default_origin_request_policy_name
  )
  origin_request_policy_id = (
    local.use_managed_origin_request_policy ?
    data.aws_cloudfront_origin_request_policy.this[0].id :
    trimspace(var.origin_request_policy_id)
  )

  use_managed_response_headers_policy = var.response_headers_policy_id == "" && trimspace(var.response_headers_policy_name) != ""
  response_headers_policy_id = (
    local.use_managed_response_headers_policy ?
    data.aws_cloudfront_response_headers_policy.this[0].id :
    trimspace(var.response_headers_policy_id) != "" ? trimspace(var.response_headers_policy_id) : null
  )

  distribution_comment = (
    trimspace(var.comment) != "" ?
    trimspace(var.comment) :
    "Ryvn CloudFront edge for ${join(", ", local.hostname_keys)}"
  )

  # Simple WAF inputs synthesize upstream aws-ss/wafv2/aws ip_set and rule
  # shapes. WAFv2 IP sets are single-family, so IPv4 and IPv6 CIDRs become
  # separate generated IP sets.
  allowlist_enabled = length(var.waf.allowed_ips) > 0
  allowlist_ipv4    = sort([for cidr in var.waf.allowed_ips : trimspace(cidr) if !strcontains(cidr, ":")])
  allowlist_ipv6    = sort([for cidr in var.waf.allowed_ips : trimspace(cidr) if strcontains(cidr, ":")])
  allowlist_families = concat(
    length(local.allowlist_ipv4) > 0 ? [{ key = "allowlist_ipv4", ip_address_version = "IPV4", addresses = local.allowlist_ipv4 }] : [],
    length(local.allowlist_ipv6) > 0 ? [{ key = "allowlist_ipv6", ip_address_version = "IPV6", addresses = local.allowlist_ipv6 }] : [],
  )
  allowlist_ip_sets = {
    for family in local.allowlist_families : family.key => {
      name               = ""
      description        = "Allowed ${family.ip_address_version} CIDRs for ${local.resource_name}."
      ip_address_version = family.ip_address_version
      addresses          = family.addresses
      tags               = var.tags
    }
  }

  managed_rule_group_names = sort(tolist(setunion(
    var.waf.managed_rules ? toset(["AWSManagedRulesCommonRuleSet"]) : toset([]),
    var.waf.managed_rule_groups,
  )))
  managed_rule_group_priority_base = max(concat([-1], [for rule in var.waf_advanced.rule : try(rule.priority, -1)])...) + 1
  managed_rule_group_rules = [
    for index, name in local.managed_rule_group_names : {
      name            = name
      priority        = local.managed_rule_group_priority_base + index
      override_action = "none"
      managed_rule_group_statement = {
        name        = name
        vendor_name = "AWS"
      }
    }
  ]

  waf_rules_before_allowlist = concat(var.waf_advanced.rule, local.managed_rule_group_rules)
  # Allow rules are always last so managed/custom rules can still block malicious
  # requests before a clean allowlisted request is allowed.
  allowlist_priority_base = max(concat([-1], [for rule in local.waf_rules_before_allowlist : try(rule.priority, -1)])...)
  allowlist_rules = [
    for index, family in local.allowlist_families : {
      name     = family.key
      priority = local.allowlist_priority_base + index + 1
      action   = "allow"
      ip_set_reference_statement = {
        arn = local.create_waf ? module.waf_ip_set[family.key].aws_wafv2_ip_set_arn : null
      }
    }
  ]

  waf_advanced_has_content = (
    length(var.waf_advanced.rule) > 0 ||
    var.waf_advanced.default_action == "block" ||
    var.waf_advanced.default_custom_response != null ||
    var.waf_advanced.association_config != null ||
    trimspace(var.waf_advanced.visibility_config.metric_name) != "" ||
    length(var.waf_advanced.custom_response_body) > 0 ||
    length(var.waf_advanced.token_domains) > 0 ||
    var.waf_advanced.enabled_logging_configuration ||
    trimspace(var.waf_advanced.name) != "" ||
    var.waf_advanced.description != null ||
    var.waf_advanced.tags != null ||
    var.waf_advanced.redacted_fields != null ||
    var.waf_advanced.logging_filter != null
  )
  waf_has_content = (
    local.allowlist_enabled ||
    length(local.managed_rule_group_names) > 0 ||
    local.waf_advanced_has_content
  )
  create_waf         = var.waf.enabled == null ? local.waf_has_content : var.waf.enabled
  waf_default_action = local.allowlist_enabled ? "block" : var.waf_advanced.default_action
  waf_name           = trimspace(var.waf_advanced.name) != "" ? trimspace(var.waf_advanced.name) : "${local.resource_name}-waf"
  waf_metric_name    = trimspace(var.waf_advanced.visibility_config.metric_name) != "" ? trimspace(var.waf_advanced.visibility_config.metric_name) : local.waf_name
  waf_ip_sets_input  = local.allowlist_ip_sets
  waf_rules_input    = concat(local.waf_rules_before_allowlist, local.allowlist_rules)
  waf_ip_sets = {
    for key, ip_set in local.waf_ip_sets_input : key => {
      name = (
        trimspace(ip_set.name) != "" ?
        trimspace(ip_set.name) :
        substr("${local.resource_name}-${trim(replace(lower(key), "/[^a-z0-9-]+/", "-"), "-")}", 0, 128)
      )
      description        = ip_set.description == null ? null : trimspace(ip_set.description)
      ip_address_version = ip_set.ip_address_version
      addresses          = [for cidr in ip_set.addresses : trimspace(cidr)]
      tags               = ip_set.tags == null ? var.tags : ip_set.tags
    }
  }
  waf_rules = [
    for rule in local.waf_rules_input : merge(rule, {
      visibility_config = merge(
        {
          cloudwatch_metrics_enabled = true
          metric_name                = try(rule.visibility_config.metric_name, rule.name)
          sampled_requests_enabled   = true
        },
        coalesce(try(rule.visibility_config, null), {})
      )
    })
  ]
  web_acl_arn = (
    local.create_waf ?
    module.waf[0].aws_wafv2_arn :
    trimspace(var.web_acl_arn) != "" ? trimspace(var.web_acl_arn) : null
  )

  standard_logging_v2_enabled = var.standard_logging_v2.enabled
  # aws_cloudwatch_log_delivery_destination.name must be 1-60 characters. The
  # default resource name can be up to 63 characters, so "${resource_name}-logs"
  # overflows. Prefer the full name when it fits and fall back to the shorter
  # name (which preserves the unique random suffix) otherwise.
  standard_logging_v2_name = (
    trimspace(var.standard_logging_v2.name) != "" ?
    trimspace(var.standard_logging_v2.name) :
    length("${local.resource_name}-logs") <= 60 ?
    "${local.resource_name}-logs" :
    "${local.short_resource_name}-logs"
  )

  required_dns_records = {
    for hostname in local.hostname_keys : hostname => {
      name    = hostname
      type    = hostname == local.managed_public_dns_root ? "ALIAS/ANAME" : "CNAME"
      content = aws_cloudfront_distribution.this.domain_name
    }
  }
}

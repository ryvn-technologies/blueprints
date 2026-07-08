module "waf_ip_set" {
  for_each = local.create_waf ? local.waf_ip_sets : {}

  source  = "aws-ss/wafv2/aws//modules/ip-set"
  version = "4.2.0"

  providers = {
    aws = aws.us_east_1
  }

  name               = each.value.name
  description        = each.value.description
  scope              = "CLOUDFRONT"
  region             = "us-east-1"
  ip_address_version = each.value.ip_address_version
  addresses          = each.value.addresses
  tags               = each.value.tags
}

module "waf" {
  count = local.create_waf ? 1 : 0

  source  = "aws-ss/wafv2/aws"
  version = "4.2.0"

  providers = {
    aws = aws.us_east_1
  }

  name        = local.waf_name
  description = var.waf_advanced.description
  scope       = "CLOUDFRONT"
  region      = "us-east-1"

  default_action          = local.waf_default_action
  default_custom_response = var.waf_advanced.default_custom_response
  association_config      = var.waf_advanced.association_config
  visibility_config = {
    cloudwatch_metrics_enabled = var.waf_advanced.visibility_config.cloudwatch_metrics_enabled
    metric_name                = local.waf_metric_name
    sampled_requests_enabled   = var.waf_advanced.visibility_config.sampled_requests_enabled
  }

  custom_response_body = var.waf_advanced.custom_response_body
  captcha_config       = var.waf_advanced.captcha_config
  challenge_config     = var.waf_advanced.challenge_config
  token_domains        = var.waf_advanced.token_domains
  rule                 = local.waf_rules
  tags                 = var.waf_advanced.tags == null ? var.tags : var.waf_advanced.tags

  enabled_web_acl_association = false
  resource_arn                = []

  enabled_logging_configuration = var.waf_advanced.enabled_logging_configuration
  log_destination_configs       = var.waf_advanced.log_destination_configs
  redacted_fields               = var.waf_advanced.redacted_fields
  logging_filter                = var.waf_advanced.logging_filter
}

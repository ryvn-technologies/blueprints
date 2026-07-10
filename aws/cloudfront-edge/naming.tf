resource "random_id" "resource_suffix" {
  byte_length = 5
}

locals {
  existing_waf_discovery_tag_keys = toset([
    "ryvn.app/blueprint",
    "ryvn.app/environment",
    "ryvn.app/installation",
  ])
  existing_waf_discovery_tags = {
    for key in local.existing_waf_discovery_tag_keys : key => trimspace(try(var.tags[key], ""))
    if trimspace(try(var.tags[key], "")) != ""
  }
  discover_existing_waf = (
    local.create_waf &&
    trimspace(var.waf_advanced.name) == "" &&
    length(local.existing_waf_discovery_tags) == length(local.existing_waf_discovery_tag_keys)
  )
}

data "aws_resourcegroupstaggingapi_resources" "existing_waf" {
  count = local.discover_existing_waf ? 1 : 0

  provider = aws.us_east_1

  dynamic "tag_filter" {
    for_each = local.existing_waf_discovery_tags

    content {
      key    = tag_filter.key
      values = [tag_filter.value]
    }
  }
}

locals {
  discovered_waf_names = local.discover_existing_waf ? sort(distinct([
    for mapping in data.aws_resourcegroupstaggingapi_resources.existing_waf[0].resource_tag_mapping_list :
    split("/", mapping.resource_arn)[length(split("/", mapping.resource_arn)) - 2]
    if strcontains(mapping.resource_arn, ":global/webacl/")
  ])) : []
  discovered_waf_resource_names = [
    for name in local.discovered_waf_names : trimsuffix(name, "-waf")
    if endswith(name, "-waf")
  ]

  name_prefix                     = trimspace(var.name_prefix)
  name_prefix_normalized          = trim(replace(lower(local.name_prefix), "/[^a-z0-9-]+/", "-"), "-")
  configured_resource_name_prefix = substr(local.name_prefix_normalized, 0, min(52, length(local.name_prefix_normalized)))
  configured_short_name_prefix    = substr(local.name_prefix_normalized, 0, min(40, length(local.name_prefix_normalized)))

  # Endpoint config changes replace the VPC origin (see vpc_origin.tf) because
  # AWS rejects UpdateVpcOrigin while the origin is attached to a distribution.
  # The fingerprint suffixes the name because AWS requires VPC origin names to
  # be unique, so both origins can coexist during the swap.
  vpc_origin_endpoint_fingerprint = substr(sha1(join(",", [
    local.vpc_origin_endpoint_arn,
    tostring(var.vpc_origin.http_port),
    tostring(var.vpc_origin.https_port),
    var.vpc_origin.origin_protocol_policy,
    join("+", sort(var.vpc_origin.origin_ssl_protocols)),
  ])), 0, 8)
  generated_resource_suffix = random_id.resource_suffix.hex
  generated_resource_name = join("-", compact([
    local.configured_resource_name_prefix,
    local.generated_resource_suffix,
  ]))
  generated_short_resource_name = join("-", compact([
    local.configured_short_name_prefix,
    local.generated_resource_suffix,
  ]))
  generated_viewer_mtls_bucket_prefix = substr("${local.generated_resource_name}-viewer-mtls-ca-", 0, 37)

  # The VPC origin cannot depend on the compatibility names captured below,
  # because those names are recovered by observing this resource during an
  # upgrade. The generated random suffix is independent and breaks that cycle.
  vpc_origin_name_base = trimspace(var.vpc_origin.name) != "" ? trimspace(var.vpc_origin.name) : local.generated_short_resource_name
  vpc_origin_name      = "${local.vpc_origin_name_base}-${local.vpc_origin_endpoint_fingerprint}"
  observed_vpc_origin_name = (
    local.create_vpc_origin && trimspace(var.vpc_origin.name) == "" ?
    aws_cloudfront_vpc_origin.this["this"].vpc_origin_endpoint_config[0].name :
    ""
  )
  observed_resource_name = (
    length(local.discovered_waf_resource_names) == 1 ?
    local.discovered_waf_resource_names[0] :
    local.observed_vpc_origin_name
  )
  legacy_generated_name_matches = regexall("^(.*)-([0-9a-f]{10})$", local.observed_resource_name)
  has_legacy_generated_name     = length(local.legacy_generated_name_matches) > 0
  legacy_name_prefix            = local.has_legacy_generated_name ? local.legacy_generated_name_matches[0][0] : ""
  legacy_resource_suffix        = local.has_legacy_generated_name ? local.legacy_generated_name_matches[0][1] : ""
  initial_resource_name = (
    local.has_legacy_generated_name ?
    local.observed_resource_name :
    local.generated_resource_name
  )
  initial_short_resource_name = (
    local.has_legacy_generated_name ?
    join("-", compact([
      substr(local.legacy_name_prefix, 0, min(40, length(local.legacy_name_prefix))),
      local.legacy_resource_suffix,
    ])) :
    local.generated_short_resource_name
  )
  initial_viewer_mtls_bucket_prefix = (
    local.has_legacy_generated_name ?
    substr("${local.legacy_name_prefix}-viewer-mtls-ca-", 0, 37) :
    local.generated_viewer_mtls_bucket_prefix
  )
}

resource "terraform_data" "resource_names" {
  input = {
    resource_name                  = local.initial_resource_name
    short_resource_name            = local.initial_short_resource_name
    viewer_mtls_bucket_name_prefix = local.initial_viewer_mtls_bucket_prefix
  }

  lifecycle {
    precondition {
      condition     = length(local.discovered_waf_resource_names) <= 1
      error_message = "Multiple tagged CloudFront WebACLs match this installation; refusing to guess which generated name to preserve."
    }

    # Preserve complete names captured from existing infrastructure. Mutable
    # inputs and installation renames must not rename attached resources.
    ignore_changes = [input]
  }
}

locals {
  resource_name                  = terraform_data.resource_names.input.resource_name
  short_resource_name            = terraform_data.resource_names.input.short_resource_name
  viewer_mtls_bucket_name_prefix = terraform_data.resource_names.input.viewer_mtls_bucket_name_prefix
}

# PR #7096 prereleases temporarily keyed the WAF module by a hash of its name.
# Preserve the instance deployed to the Guava develop validation installation
# when it returns to the stable count-based address.
moved {
  from = module.waf["10d3a6c5"]
  to   = module.waf[0]
}

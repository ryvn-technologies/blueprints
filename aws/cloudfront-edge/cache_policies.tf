data "aws_cloudfront_cache_policy" "caching_disabled" {
  provider = aws.us_east_1
  name     = "Managed-CachingDisabled"
}

# Ordered policy resources are keyed independently from behavior paths so path
# changes and behavior reordering do not replace them. Additional header names
# are normalized to lowercase, and any user-supplied Host variant is ignored.
resource "aws_cloudfront_cache_policy" "cache_behavior" {
  for_each = var.cache_policies

  provider = aws.us_east_1

  # short_resource_name is capped at 51 characters, keeping this at 69
  # characters versus CloudFront's 128-character cache-policy name limit.
  name    = "${local.short_resource_name}-behavior-${substr(sha1(each.key), 0, 8)}"
  comment = substr("Cache policy ${each.key} for ${local.resource_name}.", 0, 128)

  min_ttl     = each.value.min_ttl
  default_ttl = each.value.default_ttl
  max_ttl     = each.value.max_ttl

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "whitelist"

      headers {
        # Keep Host in the cache key so aliases sharing this distribution cannot
        # reuse each other's responses when the origin routes by hostname.
        items = concat(
          ["Host"],
          sort(distinct([
            for header in each.value.additional_headers : lower(header)
            if lower(header) != "host"
          ])),
        )
      }
    }

    query_strings_config {
      query_string_behavior = length(each.value.query_strings) == 0 ? "none" : "whitelist"

      dynamic "query_strings" {
        for_each = length(each.value.query_strings) == 0 ? [] : [each.value.query_strings]

        content {
          items = query_strings.value
        }
      }
    }
  }
}

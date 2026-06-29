locals {
  hostname_origin_rules = [
    for key, config in local.hostnames : {
      action     = "route"
      expression = local.hostname_scope_expression_by_key[key]
      ref        = "origin_route_${replace(lower(key), "/[^a-z0-9]+/", "_")}_${substr(sha1(key), 0, 8)}"
      enabled    = true
      action_parameters = {
        origin = {
          host = config.origin_hostname
          port = config.origin_port
        }
        sni = {
          value = config.origin_sni
        }
      }
    }
    if config.origin_port != 443 || config.origin_sni != config.hostname
  ]

  hostname_ssl_rules = [
    for key, config in local.hostnames : {
      action      = "set_config"
      expression  = local.hostname_scope_expression_by_key[key]
      ref         = "strict_origin_tls_${replace(lower(key), "/[^a-z0-9]+/", "_")}_${substr(sha1(key), 0, 8)}"
      enabled     = true
      description = "Enforce strict origin TLS for ${config.hostname}"
      action_parameters = {
        ssl = "strict"
      }
    }
  ]
}

# Origin routing: only needed when origin_port or origin_sni differs from
# Cloudflare's proxy defaults; otherwise the proxied DNS record routes traffic.
resource "cloudflare_ruleset" "origin" {
  count = length(local.hostname_origin_rules) > 0 ? 1 : 0

  zone_id     = var.zone_id
  name        = "${local.ruleset_name_prefix} origin routing"
  description = "Origin routing entry-point ruleset managed by this Terraform module."
  kind        = "zone"
  phase       = "http_request_origin"
  rules       = local.hostname_origin_rules
}

# Strict server-side TLS on the Cloudflare-to-origin hop. This is intentionally
# hostname-scoped so one installation does not change TLS behavior for unrelated
# proxied hostnames in the same zone.
resource "cloudflare_ruleset" "origin_tls" {
  count = length(local.hostnames) > 0 ? 1 : 0

  zone_id     = var.zone_id
  name        = "${local.ruleset_name_prefix} origin TLS"
  description = "Origin TLS configuration entry-point ruleset managed by this Terraform module."
  kind        = "zone"
  phase       = "http_config_settings"
  rules       = local.hostname_ssl_rules
}

# Per-hostname Authenticated Origin Pulls: the gateway validates Cloudflare's
# client cert on every proxied request for these hostnames.
resource "cloudflare_authenticated_origin_pulls" "per_hostname" {
  for_each = local.hostnames

  zone_id = var.zone_id
  config = [{
    hostname = each.value.hostname
    enabled  = true
    cert_id  = each.value.authenticated_origin_pulls_certificate_id
  }]
}

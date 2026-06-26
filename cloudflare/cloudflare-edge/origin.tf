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

# Mutual TLS on the Cloudflare-to-origin hop: strict server-side TLS (Cloudflare
# validates the gateway cert) plus per-hostname Authenticated Origin Pulls (the
# gateway validates Cloudflare's client cert).
resource "cloudflare_zone_setting" "ssl" {
  count = length(local.hostnames) > 0 ? 1 : 0

  zone_id    = var.zone_id
  setting_id = "ssl"
  value      = "strict"
}

resource "cloudflare_authenticated_origin_pulls" "per_hostname" {
  for_each = local.hostnames

  zone_id = var.zone_id
  config = [{
    hostname = each.value.hostname
    enabled  = true
    cert_id  = each.value.authenticated_origin_pulls_certificate_id
  }]
}

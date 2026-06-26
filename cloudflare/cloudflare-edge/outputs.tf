output "dns_records" {
  description = "The proxied DNS records this module manages, keyed by hostname."
  value = {
    for key, record in cloudflare_dns_record.this : key => {
      id      = record.id
      name    = record.name
      type    = record.type
      content = record.content
      proxied = record.proxied
    }
  }
}

output "required_dns_records" {
  description = "Authoritative CNAME records to create outside Cloudflare when this zone uses Cloudflare partial/CNAME setup."
  value = {
    for key, config in local.hostnames : key => {
      name    = config.hostname
      type    = "CNAME"
      content = "${config.hostname}.cdn.cloudflare.net"
    }
  }
}

output "hostnames" {
  description = "Each configured hostname with its effective origin, client certificate, and WAF scope."
  value = {
    for key, config in local.hostnames : key => {
      hostname                                  = config.hostname
      origin_hostname                           = config.origin_hostname
      origin_sni                                = config.origin_sni
      origin_port                               = config.origin_port
      authenticated_origin_pulls_certificate_id = config.authenticated_origin_pulls_certificate_id
      scope_expression                          = local.hostname_scope_expression_by_key[key]
      dns_record_id                             = try(cloudflare_dns_record.this[key].id, null)
    }
  }
}

output "ruleset_ids" {
  description = "Cloudflare ruleset IDs this module manages."
  value = merge(
    length(cloudflare_ruleset.origin) > 0 ? {
      origin = cloudflare_ruleset.origin[0].id
    } : {},
    length(cloudflare_ruleset.managed_waf) > 0 ? {
      managed_waf = cloudflare_ruleset.managed_waf[0].id
    } : {},
    length(cloudflare_ruleset.managed_response_waf) > 0 ? {
      managed_response_waf = cloudflare_ruleset.managed_response_waf[0].id
    } : {},
    length(cloudflare_ruleset.custom_waf) > 0 ? {
      custom_waf = cloudflare_ruleset.custom_waf[0].id
    } : {},
    length(cloudflare_ruleset.rate_limit) > 0 ? {
      rate_limit = cloudflare_ruleset.rate_limit[0].id
    } : {}
  )
}

output "authenticated_origin_pulls" {
  description = "Authenticated Origin Pulls state: the Cloudflare client certificate each hostname presents to the origin."
  value = {
    enabled = length(local.hostnames) > 0
    scope   = length(local.hostnames) > 0 ? "per-hostname" : "disabled"
    hostnames = {
      for key, config in local.hostnames : key => {
        hostname       = config.hostname
        certificate_id = config.authenticated_origin_pulls_certificate_id
      }
    }
    certificate_source = length(local.hostnames) > 0 ? "existing-cloudflare-certificate" : "none"
  }
}

output "cloudflare_ip_ranges" {
  description = "Cloudflare IP ranges for cloud security-group or firewall allowlists."
  value = {
    ipv4_cidrs = data.cloudflare_ip_ranges.this.ipv4_cidrs
    ipv6_cidrs = data.cloudflare_ip_ranges.this.ipv6_cidrs
    etag       = data.cloudflare_ip_ranges.this.etag
  }
}

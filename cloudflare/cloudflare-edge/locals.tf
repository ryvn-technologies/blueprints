locals {
  hostname_keys                             = sort(tolist(var.hostnames))
  origin_hostname                           = trimspace(var.origin_hostname)
  origin_sni                                = trimspace(var.origin_sni)
  authenticated_origin_pulls_certificate_id = trimspace(var.authenticated_origin_pulls_certificate_id)
  ruleset_name_prefix                       = trimspace(var.ruleset_name_prefix)

  # Hostnames share the environment gateway; SNI defaults to the request host.
  hostnames = {
    for hostname in local.hostname_keys : hostname => {
      hostname                                  = hostname
      origin_hostname                           = local.origin_hostname
      origin_port                               = var.origin_port
      origin_sni                                = local.origin_sni != "" ? local.origin_sni : hostname
      authenticated_origin_pulls_certificate_id = local.authenticated_origin_pulls_certificate_id
      dns_record = {
        name    = hostname
        type    = "CNAME"
        content = local.origin_hostname
        ttl     = 1
        proxied = true
        comment = null
      }
    }
  }

  hostname_scope_expression_by_key = {
    for key, config in local.hostnames : key => "http.host eq \"${config.hostname}\""
  }
}

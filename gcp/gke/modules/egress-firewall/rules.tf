locals {
  resource_name = "egress-${substr(var.name, 0, 32)}-${substr(sha256(var.name), 0, 8)}"
  web_ports     = { http = 80, https = 443 }
  class_policy  = { for class, c in var.classes : class => var.policies[c.policy_key] }
  customer_domain_rules = merge({}, [for class, c in var.classes : merge({}, [
    for key, rule in local.class_policy[class].domain_allow : {
      for domain in rule.domains : "${class}/domain/${key}/${rule.protocol}/${local.web_ports[rule.protocol]}/${domain}" => {
        class   = class, policy_key = c.policy_key, rule_key = key, origin = "customer"
        domain  = domain, protocol = rule.protocol, destination_port = local.web_ports[rule.protocol]
        sources = c.sources, profile_key = "${class}/${rule.protocol}", bypasses_domain_matching = false
      }
    }
  ]...)]...)
  platform_domain_rules = contains(keys(var.classes), "cluster") ? {
    for domain in var.platform_https_domains : "cluster/platform/https/443/${domain}" => {
      class       = "cluster", policy_key = var.classes.cluster.policy_key, rule_key = null, origin = "platform"
      domain      = domain, protocol = "https", destination_port = 443, sources = var.classes.cluster.sources
      profile_key = "cluster/https", bypasses_domain_matching = false
    }
  } : {}
  domain_rules = merge(local.customer_domain_rules, local.platform_domain_rules)
  network_rules = merge({}, [for class, c in var.classes : {
    for key, rule in local.class_policy[class].network_allow : "${class}/network/${key}" => {
      class        = class, policy_key = c.policy_key, rule_key = key, origin = "customer"
      destinations = sort(tolist(rule.destination_ipv4_cidrs)), sources = c.sources
      protocol     = rule.protocol, ports = [for p in sort([for port in rule.destination_ports : tostring(port)]) : p]
      reason       = rule.reason, bypasses_domain_matching = true
    }
  }]...)
  url_profiles = merge({}, [for class, c in var.classes : {
    for protocol, port in local.web_ports : "${class}/${protocol}" => {
      class   = class, protocol = protocol, port = port, sources = c.sources
      domains = sort(distinct([for r in values(local.domain_rules) : r.domain if r.profile_key == "${class}/${protocol}"]))
      filters = merge(
        length([for r in values(local.domain_rules) : r if r.profile_key == "${class}/${protocol}"]) > 0 ? {
          allow = { priority = 100, action = "ALLOW", urls = sort(distinct([for r in values(local.domain_rules) : r.domain if r.profile_key == "${class}/${protocol}"])) }
        } : {},
        { deny = { priority = 1000, action = "DENY", urls = ["*"] } },
      )
    }
  }]...)

  # Content-independent identities keep other rule priorities stable on update.
  firewall_internal_priority = 10000
  firewall_network_band      = 100000000
  firewall_inspection_band   = 500000000
  firewall_deny_priority     = 1000000000
  firewall_network_rules = { for key, r in local.network_rules : key => {
    priority = local.firewall_network_band + parseint(substr(sha256(key), 0, 7), 16)
    action   = "allow", sources = r.sources, destinations = r.destinations, destination_context = null
    layer4   = [{ ip_protocol = r.protocol, ports = r.ports }]
  } }
  inspection_rules = { for key, p in local.url_profiles : key => {
    priority = local.firewall_inspection_band + parseint(substr(sha256(key), 0, 7), 16)
    action   = "apply_security_profile_group", sources = p.sources, destinations = ["0.0.0.0/0"]
    # Global Google APIs are NON_INTERNET even with public IPs and NAT.
    destination_context = null, layer4 = [{ ip_protocol = "tcp", ports = [tostring(p.port)] }]
  } }
  firewall_default_deny_rule = {
    priority            = local.firewall_deny_priority, action = "deny"
    sources             = ["0.0.0.0/0"], destinations = ["0.0.0.0/0"]
    destination_context = null, layer4 = [{ ip_protocol = "all", ports = [] }]
  }
  firewall_default_deny_ipv6_rule = merge(local.firewall_default_deny_rule, {
    priority = local.firewall_deny_priority + 1
    sources  = ["::/0"], destinations = ["::/0"]
  })
  internal_rules = length(var.internal_destination_cidrs) > 0 ? {
    internal = {
      priority            = local.firewall_internal_priority, action = "allow"
      sources             = ["0.0.0.0/0"], destinations = var.internal_destination_cidrs
      destination_context = null, layer4 = [{ ip_protocol = "all", ports = [] }]
    }
  } : {}
  direct_rules = merge(local.internal_rules, local.firewall_network_rules)
  priorities   = concat([local.firewall_internal_priority, local.firewall_deny_priority, local.firewall_default_deny_ipv6_rule.priority], [for r in values(local.firewall_network_rules) : r.priority], [for r in values(local.inspection_rules) : r.priority])
}

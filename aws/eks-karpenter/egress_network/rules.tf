# Rule compiler: turns per-class policies into one STRICT_ORDER Suricata rule
# set. Every generated rule carries a stable identity whose SHA-1 prefix is its
# SID, so adding an unrelated rule never renumbers others:
#   <class>/domain/<rule key>/<protocol>/<port>/<domain>   customer domain rule
#   cluster/platform/https/443/<domain>                    platform baseline
#   <class>/network/<rule key>                             customer IP exception
locals {
  empty_policy        = { domain_allow = {}, network_allow = {} }
  class_policy        = { for class, policy_key in local.class_policies : class => lookup(var.policies, policy_key, local.empty_policy) }
  web_ports           = { http = 80, https = 443 }
  rule_group_capacity = 30000
  # AWS: one stateful Suricata rule consumes one capacity unit; the rules string
  # is capped at 2,000,000 bytes; Suricata parses a rule as one line of at most
  # 8192 bytes.
  max_rule_bytes    = 8192
  max_rules_bytes   = 2000000
  protocol_drop_sid = 100000001
  reserved_sids     = [local.protocol_drop_sid]

  policy_domains = distinct(flatten([for policy in values(var.policies) : [for rule in values(policy.domain_allow) : tolist(rule.domains)]]))

  # Hosts a class's own policy allows per protocol; used for provenance flags only.
  class_customer_domains = { for class, policy in local.class_policy : class => {
    for protocol in keys(local.web_ports) : protocol => toset(flatten([
      for rule in values(policy.domain_allow) : tolist(rule.domains) if rule.protocol == protocol
    ]))
  } }

  # An exact name anchors both ends of the SNI/Host; a *. suffix anchors the
  # end only and keeps the leading dot, so the apex itself is not matched.
  domain_match = { for protocol in keys(local.web_ports) : protocol => {
    for domain in distinct(concat(local.policy_domains, tolist(var.platform_https_domains))) : domain => join("", [
      protocol == "http" ? "http.host; " : "tls.sni; ",
      "content:\"${trimprefix(domain, "*")}\"; ",
      startswith(domain, "*.") ? "" : "startswith; ",
      "endswith; ",
      protocol == "http" ? "" : "nocase; ",
    ])
  } }

  customer_domain_rules = flatten([for class, policy in local.class_policy : [for key, rule in policy.domain_allow : [
    for domain in sort(tolist(rule.domains)) : {
      identity            = "${class}/domain/${key}/${rule.protocol}/${local.web_ports[rule.protocol]}/${domain}"
      source_class        = class
      policy_key          = local.class_policies[class]
      domain_rule_key     = key
      origin              = "customer"
      platform_required   = class == "cluster" && rule.protocol == "https" && contains(var.platform_https_domains, domain)
      customer_configured = true
      kind                = "domain"
      protocol            = rule.protocol
      destination_ports   = [local.web_ports[rule.protocol]]
      domain              = domain
      destination_cidrs   = []
      reason              = "${rule.protocol} rule ${key} in policy ${local.class_policies[class]}"
      match               = local.domain_match[rule.protocol][domain]
    }
  ]]])

  platform_domain_rules = [for domain in sort(tolist(var.platform_https_domains)) : {
    identity            = "cluster/platform/https/443/${domain}"
    source_class        = "cluster"
    policy_key          = var.cluster_policy_key
    domain_rule_key     = null
    origin              = "platform"
    platform_required   = true
    customer_configured = contains(local.class_customer_domains["cluster"]["https"], domain)
    kind                = "domain"
    protocol            = "https"
    destination_ports   = [443]
    domain              = domain
    destination_cidrs   = []
    reason              = "platform baseline (platform_https_domains)"
    match               = local.domain_match["https"][domain]
  }]

  network_rules = flatten([for class, policy in local.class_policy : [for key, rule in policy.network_allow : {
    identity            = "${class}/network/${key}"
    source_class        = class
    policy_key          = local.class_policies[class]
    domain_rule_key     = null
    origin              = "customer"
    platform_required   = false
    customer_configured = true
    kind                = "network"
    protocol            = rule.protocol
    destination_ports   = [for p in sort([for port in rule.destination_ports : format("%05d", port)]) : tonumber(p)]
    domain              = null
    destination_cidrs   = sort(tolist(rule.destination_ipv4_cidrs))
    reason              = rule.reason
    match               = rule.protocol == "tcp" ? "flow:to_server; " : ""
  }]])

  compiled_rules = [for rule in concat(local.network_rules, local.platform_domain_rules, local.customer_domain_rules) : merge(rule, {
    sid = max(1, parseint(substr(sha1(rule.identity), 0, 8), 16))
    # TCP exceptions on 80/443 pass raw IPs without a Host/SNI match.
    bypasses_domain_matching = rule.kind == "network" && rule.protocol == "tcp" && length(setintersection(toset(rule.destination_ports), toset(values(local.web_ports)))) > 0
  })]

  named_rules = [for rule in local.compiled_rules : merge(rule, {
    text = rule.kind == "network" ? join("", [
      "pass ${rule.protocol} [${join(",", local.class_sources[rule.source_class])}] any -> [${join(",", rule.destination_cidrs)}] [${join(",", rule.destination_ports)}] ",
      "(${rule.match}sid:${rule.sid}; rev:1;)",
      ]) : join("", [
      "pass ${rule.protocol == "http" ? "http" : "tls"} [${join(",", local.class_sources[rule.source_class])}] any -> !$HOME_NET ${rule.destination_ports[0]} ",
      "(flow:to_server; ${rule.match}sid:${rule.sid}; rev:1;)",
    ])
  })]

  # Ordered so that an identity listed later never shifts an earlier rule.
  suricata_rules = join("\n", concat(
    ["drop ip $HOME_NET any -> !$HOME_NET any (ip_proto:!TCP; ip_proto:!UDP; sid:${local.protocol_drop_sid}; rev:1;)"],
    [for rule in local.named_rules : rule.text]
  ))

  generated_sids = [for rule in local.compiled_rules : rule.sid]

  effective_rules = { for rule in local.named_rules : rule.identity => {
    sid                      = rule.sid
    source_class             = rule.source_class
    policy_key               = rule.policy_key
    domain_rule_key          = rule.domain_rule_key
    origin                   = rule.origin
    platform_required        = rule.platform_required
    customer_configured      = rule.customer_configured
    kind                     = rule.kind
    protocol                 = rule.protocol
    destination_ports        = rule.destination_ports
    domain                   = rule.domain
    destination_cidrs        = rule.destination_cidrs
    reason                   = rule.reason
    bypasses_domain_matching = rule.bypasses_domain_matching
  } }
}

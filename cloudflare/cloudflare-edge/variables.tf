variable "cloudflare_api_token" {
  description = "API token the module uses to authenticate to Cloudflare, scoped to this single zone (no account-level access is needed). Grant only the permissions required by the features you enable; see the permission table in README.md."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = var.cloudflare_api_token != "" && trimspace(var.cloudflare_api_token) == var.cloudflare_api_token
    error_message = "cloudflare_api_token must be non-empty and must not have leading or trailing whitespace."
  }
}

variable "zone_id" {
  description = "ID of the Cloudflare zone that owns these hostnames: the 32-character hexadecimal ID shown on the zone's overview page in the Cloudflare dashboard. Every DNS record, ruleset, and zone setting this module manages is created in this zone."
  type        = string
  nullable    = false

  validation {
    condition     = var.zone_id != "" && trimspace(var.zone_id) == var.zone_id
    error_message = "zone_id must be a non-empty Cloudflare zone ID with no leading or trailing whitespace."
  }
}

variable "ruleset_name_prefix" {
  description = "Prefix used for Cloudflare ruleset names created by this module. Defaults to \"ryvn\"; override to namespace rulesets per environment or installation."
  type        = string
  default     = "ryvn"
  nullable    = false

  validation {
    condition     = var.ruleset_name_prefix != "" && trimspace(var.ruleset_name_prefix) == var.ruleset_name_prefix
    error_message = "ruleset_name_prefix must be non-empty and must not have leading or trailing whitespace."
  }
}

variable "origin_hostname" {
  description = "Public DNS name of the default origin Cloudflare forwards proxied traffic to."
  type        = string
  nullable    = false

  validation {
    condition = (
      var.origin_hostname != "" &&
      trimspace(var.origin_hostname) == var.origin_hostname &&
      length(regexall("\\s", var.origin_hostname)) == 0 &&
      !strcontains(var.origin_hostname, "://") &&
      !strcontains(var.origin_hostname, "/") &&
      !strcontains(var.origin_hostname, ":") &&
      !strcontains(var.origin_hostname, "*")
    )
    error_message = "origin_hostname must be a non-empty hostname with no whitespace, URL scheme, path, port, or wildcard."
  }
}

variable "origin_port" {
  description = "TCP port Cloudflare uses when connecting to the default origin."
  type        = number
  default     = 443
  nullable    = false

  validation {
    condition     = var.origin_port > 0 && var.origin_port <= 65535
    error_message = "origin_port must be a valid TCP port."
  }
}

variable "origin_sni" {
  description = "SNI value Cloudflare uses for the default origin. Leave empty to use the request hostname."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition = (
      trimspace(var.origin_sni) == var.origin_sni &&
      length(regexall("\\s", var.origin_sni)) == 0 &&
      !strcontains(var.origin_sni, "://") &&
      !strcontains(var.origin_sni, "/") &&
      !strcontains(var.origin_sni, ":") &&
      !strcontains(var.origin_sni, "*")
    )
    error_message = "origin_sni must be a hostname with no whitespace, URL scheme, path, port, or wildcard."
  }
}

variable "authenticated_origin_pulls_certificate_id" {
  description = "Cloudflare per-hostname Authenticated Origin Pulls client certificate ID that Cloudflare presents to the origin."
  type        = string
  nullable    = false

  validation {
    condition = (
      var.authenticated_origin_pulls_certificate_id != "" &&
      trimspace(var.authenticated_origin_pulls_certificate_id) == var.authenticated_origin_pulls_certificate_id
    )
    error_message = "authenticated_origin_pulls_certificate_id must be non-empty and must not have leading or trailing whitespace."
  }
}

variable "hostnames" {
  description = "Exact hostnames Cloudflare proxies to the origin, such as api.example.com. Every hostname shares the module's origin settings because one environment has a single gateway. Wildcards are rejected because Cloudflare per-hostname Authenticated Origin Pulls does not reliably present client certificates for wildcard associations."
  type        = set(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for hostname in var.hostnames :
      hostname != "" &&
      trimspace(hostname) == hostname &&
      length(regexall("\\s", hostname)) == 0 &&
      !strcontains(hostname, "://") &&
      !strcontains(hostname, "/") &&
      !strcontains(hostname, ":") &&
      !strcontains(hostname, "*")
    ])
    error_message = "hostnames entries must be exact hostnames such as api.example.com. Wildcard hostnames are not supported with per-hostname Authenticated Origin Pulls."
  }
}

variable "waf" {
  description = "Cloudflare WAF for the proxied hostnames, configured as zone-scoped rulesets. Disabled by default; set enabled = true to turn it on. See the WAF section in README.md for the available rules and examples."
  type = object({
    enabled          = optional(bool, false)
    scope_expression = optional(string, "")
    ip_allowlist     = optional(list(string), [])
    ip_blocklist     = optional(list(string), [])
    managed_rule_exceptions = optional(list(object({
      ref         = string
      description = optional(string)
      expression  = optional(string, "")
      enabled     = optional(bool, true)
      rules       = optional(map(list(string)), {})
      rulesets    = optional(list(string), [])
      logging     = optional(object({ enabled = optional(bool) }))
    })), [])
    managed_rules = optional(object({
      # rule_overrides / category_overrides accept the Cloudflare-native
      # override shape (rules: id + optional action/enabled/score_threshold;
      # categories: category + optional action/enabled). Kept as list(any) so
      # callers are not boxed into a module-specific schema; the provider
      # validates the contents.
      cloudflare_managed = optional(object({
        enabled            = optional(bool, false)
        ref                = optional(string, "execute_cloudflare_managed_ruleset")
        description        = optional(string, "Execute Cloudflare Managed Ruleset")
        expression         = optional(string, "")
        rule_overrides     = optional(list(any), [])
        category_overrides = optional(list(any), [])
        logging            = optional(object({ enabled = optional(bool) }))
      }), {})
      owasp = optional(object({
        enabled            = optional(bool, false)
        ref                = optional(string, "execute_owasp_core_ruleset")
        description        = optional(string, "Execute Cloudflare OWASP Core Ruleset")
        expression         = optional(string, "")
        action             = optional(string, "log")
        paranoia_level     = optional(number, 1)
        score_threshold    = optional(number, 60)
        rule_overrides     = optional(list(any), [])
        category_overrides = optional(list(any), [])
        logging            = optional(object({ enabled = optional(bool) }))
      }), {})
      # Cloudflare Free Managed Ruleset: high-impact, widely exploited
      # vulnerabilities. Available on all plans; on the Free plan Cloudflare
      # auto-deploys it and it is not configurable, so this toggle is most
      # relevant to accounts that deploy it via a custom entry-point. Runs in the
      # same http_request_firewall_managed phase as cloudflare_managed.
      cloudflare_free = optional(object({
        enabled            = optional(bool, false)
        ref                = optional(string, "execute_cloudflare_free_managed_ruleset")
        description        = optional(string, "Execute Cloudflare Free Managed Ruleset")
        expression         = optional(string, "")
        rule_overrides     = optional(list(any), [])
        category_overrides = optional(list(any), [])
        logging            = optional(object({ enabled = optional(bool) }))
      }), {})
      # Cloudflare Sensitive Data Detection: monitors responses for sensitive
      # data exposure. Requires an Enterprise plan and runs in the
      # http_response_firewall_managed phase; its rules can only log (you cannot
      # block a response that was already sent), so this populates a separate
      # response-phase ruleset rather than the request-phase managed ruleset.
      sensitive_data_detection = optional(object({
        enabled            = optional(bool, false)
        ref                = optional(string, "execute_sensitive_data_detection")
        description        = optional(string, "Execute Cloudflare Sensitive Data Detection")
        expression         = optional(string, "")
        rule_overrides     = optional(list(any), [])
        category_overrides = optional(list(any), [])
        logging            = optional(object({ enabled = optional(bool) }))
      }), {})
    }), {})
    custom_rules = optional(list(object({
      ref         = string
      action      = string
      description = optional(string)
      expression  = optional(string, "")
      enabled     = optional(bool, true)
      logging     = optional(object({ enabled = optional(bool) }))
    })), [])
    rate_limit_rules = optional(list(object({
      ref                        = string
      action                     = string
      characteristics            = list(string)
      period                     = number
      description                = optional(string)
      expression                 = optional(string, "")
      enabled                    = optional(bool, true)
      counting_expression        = optional(string)
      mitigation_timeout         = optional(number)
      requests_per_period        = optional(number)
      requests_to_origin         = optional(bool)
      score_per_period           = optional(number)
      score_response_header_name = optional(string)
      logging                    = optional(object({ enabled = optional(bool) }))
    })), [])
    # Escape hatch: native Cloudflare ruleset rule objects passed through
    # verbatim to the matching phase, for shapes the typed inputs above do not
    # model (custom action_parameters, exposed_credential_check, advanced skip
    # targets, executing extra managed rulesets, etc.). Typed as `any` so
    # callers write the exact provider rule shape without this module imposing a
    # schema, and so heterogeneous rules never trip Terraform list-unification.
    # Each rule's expression is still ANDed with the hostname scope, so advanced
    # rules cannot match traffic for hostnames this module does not manage.
    # Advanced rules are appended after the typed rules in their phase. The keys
    # map to phases: custom -> http_request_firewall_custom, managed ->
    # http_request_firewall_managed, managed_response ->
    # http_response_firewall_managed, rate_limit -> http_ratelimit.
    advanced = optional(object({
      custom           = optional(any, [])
      managed          = optional(any, [])
      managed_response = optional(any, [])
      rate_limit       = optional(any, [])
    }), {})
    # Escape hatch for Cloudflare's built-in ruleset IDs. Most users never set
    # this. Override managed to point a ruleset alias at a different Cloudflare
    # ruleset ID (or register a new alias for managed_rule_exceptions to
    # target), and owasp_score_rule to override the OWASP anomaly-score rule ID
    # if Cloudflare changes it.
    cloudflare_ruleset_ids = optional(object({
      managed          = optional(map(string), {})
      owasp_score_rule = optional(string, "")
    }), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains([1, 2, 3, 4], var.waf.managed_rules.owasp.paranoia_level)
    error_message = "waf.managed_rules.owasp.paranoia_level must be one of 1, 2, 3, or 4."
  }

  validation {
    condition     = contains(["log", "block", "challenge", "js_challenge", "managed_challenge"], var.waf.managed_rules.owasp.action)
    error_message = "waf.managed_rules.owasp.action must be one of log, block, challenge, js_challenge, or managed_challenge."
  }

  validation {
    condition = alltrue([
      for exception in var.waf.managed_rule_exceptions :
      length(exception.rules) > 0 || length(exception.rulesets) > 0
    ])
    error_message = "Each waf.managed_rule_exceptions entry must set rules or rulesets."
  }

  validation {
    condition = alltrue([
      for exception in var.waf.managed_rule_exceptions :
      !(length(exception.rules) > 0 && length(exception.rulesets) > 0)
    ])
    error_message = "Each waf.managed_rule_exceptions entry must set only one of rules or rulesets."
  }

  validation {
    condition = alltrue(flatten([
      for exception in var.waf.managed_rule_exceptions : [
        for ruleset_alias in keys(exception.rules) :
        contains(concat(["cloudflare_managed", "owasp", "cloudflare_free"], keys(var.waf.cloudflare_ruleset_ids.managed)), ruleset_alias)
      ]
    ]))
    error_message = "waf.managed_rule_exceptions.rules keys must use known ruleset aliases such as cloudflare_managed or owasp."
  }

  validation {
    condition = alltrue(flatten([
      for exception in var.waf.managed_rule_exceptions : [
        for ruleset_alias in exception.rulesets :
        contains(concat(["cloudflare_managed", "owasp", "cloudflare_free"], keys(var.waf.cloudflare_ruleset_ids.managed)), ruleset_alias)
      ]
    ]))
    error_message = "waf.managed_rule_exceptions.rulesets entries must use known ruleset aliases such as cloudflare_managed or owasp."
  }

  validation {
    condition = alltrue([
      for rule in var.waf.custom_rules :
      rule.ref != "" &&
      trimspace(rule.ref) == rule.ref &&
      rule.action != "" &&
      trimspace(rule.action) == rule.action
    ])
    error_message = "Each waf.custom_rules entry must include ref and action."
  }

  validation {
    condition = alltrue([
      for rule in var.waf.rate_limit_rules :
      rule.ref != "" &&
      trimspace(rule.ref) == rule.ref &&
      rule.action != "" &&
      trimspace(rule.action) == rule.action &&
      rule.period > 0 &&
      length(rule.characteristics) > 0
    ])
    error_message = "Each waf.rate_limit_rules entry must include ref, action, at least one characteristic, and a positive period."
  }

  validation {
    condition     = !var.waf.enabled || length(var.hostnames) > 0 || trimspace(var.waf.scope_expression) != ""
    error_message = "waf.scope_expression is required when waf.enabled is true and no hostnames are configured."
  }

  validation {
    condition     = (length(var.waf.ip_allowlist) == 0 && length(var.waf.ip_blocklist) == 0) || var.waf.enabled
    error_message = "waf.ip_allowlist and waf.ip_blocklist require waf.enabled = true."
  }

  validation {
    condition = alltrue([
      for ip in concat(var.waf.ip_allowlist, var.waf.ip_blocklist) :
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}(/[0-9]{1,2})?$", ip)) ||
      can(regex("^[0-9A-Fa-f:]+(/[0-9]{1,3})?$", ip))
    ])
    error_message = "waf.ip_allowlist and waf.ip_blocklist entries must be IPv4 or IPv6 addresses or CIDR ranges."
  }

  validation {
    condition     = length(var.waf.custom_rules) == length(distinct([for rule in var.waf.custom_rules : rule.ref]))
    error_message = "waf.custom_rules[*].ref must be unique."
  }

  validation {
    condition = alltrue([
      for rule in var.waf.custom_rules :
      !contains(["ip_allowlist", "ip_blocklist"], rule.ref)
    ])
    error_message = "waf.custom_rules[*].ref cannot use the reserved names ip_allowlist or ip_blocklist; use waf.ip_allowlist and waf.ip_blocklist instead."
  }

  validation {
    condition = alltrue([
      for rule in var.waf.custom_rules :
      contains(["block", "managed_challenge", "js_challenge", "challenge", "log", "skip"], rule.action)
    ])
    error_message = "waf.custom_rules[*].action must be one of block, managed_challenge, js_challenge, challenge, log, or skip."
  }

  validation {
    condition     = length(var.waf.rate_limit_rules) == length(distinct([for rule in var.waf.rate_limit_rules : rule.ref]))
    error_message = "waf.rate_limit_rules[*].ref must be unique."
  }

  validation {
    condition = alltrue([
      for rule in var.waf.rate_limit_rules :
      contains(["block", "managed_challenge", "js_challenge", "challenge", "log"], rule.action)
    ])
    error_message = "waf.rate_limit_rules[*].action must be one of block, managed_challenge, js_challenge, challenge, or log."
  }

  validation {
    condition     = length(var.waf.managed_rule_exceptions) == length(distinct([for exception in var.waf.managed_rule_exceptions : exception.ref]))
    error_message = "waf.managed_rule_exceptions[*].ref must be unique."
  }

  validation {
    condition = !var.waf.enabled || anytrue([
      var.waf.managed_rules.cloudflare_managed.enabled,
      var.waf.managed_rules.owasp.enabled,
      var.waf.managed_rules.cloudflare_free.enabled,
      var.waf.managed_rules.sensitive_data_detection.enabled,
      length(var.waf.custom_rules) > 0,
      length(var.waf.rate_limit_rules) > 0,
      length(var.waf.ip_allowlist) > 0,
      length(var.waf.ip_blocklist) > 0,
      length(var.waf.advanced.custom) > 0,
      length(var.waf.advanced.managed) > 0,
      length(var.waf.advanced.managed_response) > 0,
      length(var.waf.advanced.rate_limit) > 0,
    ])
    error_message = "waf.enabled is true but no protective rule is active. Enable a managed_rules ruleset (cloudflare_managed, owasp, cloudflare_free, or sensitive_data_detection), or add custom_rules, rate_limit_rules, ip_allowlist, ip_blocklist, or advanced rules (managed_rule_exceptions alone do not count)."
  }

  validation {
    condition = var.waf.enabled || (
      length(var.waf.advanced.custom) == 0 &&
      length(var.waf.advanced.managed) == 0 &&
      length(var.waf.advanced.managed_response) == 0 &&
      length(var.waf.advanced.rate_limit) == 0
    )
    error_message = "waf.advanced rules require waf.enabled = true."
  }

  validation {
    condition = alltrue([
      for rule in var.waf.rate_limit_rules :
      rule.requests_per_period != null || rule.score_per_period != null
    ])
    error_message = "Each waf.rate_limit_rules entry must set requests_per_period or score_per_period; otherwise the rule has no threshold and never triggers."
  }
}

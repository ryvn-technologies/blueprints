locals {
  hostname_scope_expression = (
    length(local.hostname_keys) == 0 ? "" :
    length(local.hostname_keys) == 1 ? "http.host eq \"${local.hostname_keys[0]}\"" :
    format("http.host in {%s}", join(" ", [for hostname in local.hostname_keys : "\"${hostname}\""]))
  )
  # scope_expression narrows (ANDs with) the hostname scope so rules can never
  # match traffic for hostnames this module does not manage. With no hostnames
  # configured it stands alone (the no-hostnames escape hatch).
  waf_scope_expression = (
    local.hostname_scope_expression == "" ? var.waf.scope_expression :
    trimspace(var.waf.scope_expression) != "" ? "(${local.hostname_scope_expression}) and (${var.waf.scope_expression})" :
    local.hostname_scope_expression
  )
  # Global Cloudflare WAF ruleset IDs. Override via var.waf.cloudflare_ruleset_ids
  # if Cloudflare reissues one. Source: https://developers.cloudflare.com/waf/managed-rules/
  waf_default_ruleset_ids = {
    cloudflare_managed       = "efb7b8c949ac4650a09736fc376e9aee"
    owasp                    = "4814384a9e5d4991b9815dcfc25d2f1f"
    cloudflare_free          = "77454fe2d30c4220b5701f6fdfb893ba"
    sensitive_data_detection = "e22d83c647c64a3eae91b71b499d988e"
  }
  waf_default_owasp_score_rule_id = "6179ae15870a4bb7b2d480d4843b323c"

  waf_ruleset_ids = merge(local.waf_default_ruleset_ids, var.waf.cloudflare_ruleset_ids.managed)
  waf_owasp_score_rule_id = (
    var.waf.cloudflare_ruleset_ids.owasp_score_rule != "" ?
    var.waf.cloudflare_ruleset_ids.owasp_score_rule :
    local.waf_default_owasp_score_rule_id
  )
  waf_owasp_disabled_categories_by_paranoia_level = {
    1 = ["paranoia-level-2", "paranoia-level-3", "paranoia-level-4"]
    2 = ["paranoia-level-3", "paranoia-level-4"]
    3 = ["paranoia-level-4"]
    4 = []
  }

  # Built with an `if var.waf.enabled` filter rather than an outer
  # `enabled ? [...] : []` so the heterogeneous rule tuple is never compared
  # against an empty tuple (which Terraform rejects when the element shapes
  # differ). The same idiom is used for every WAF rule list below.
  waf_managed_rule_exceptions = [
    for exception in var.waf.managed_rule_exceptions : merge(
      {
        action = "skip"
        expression = trimspace(try(exception.expression, "")) != "" ? (
          "(${local.waf_scope_expression}) and (${exception.expression})"
        ) : local.waf_scope_expression
        ref     = exception.ref
        enabled = try(exception.enabled, true)
        action_parameters = merge(
          length(exception.rules) > 0 ? {
            rules = {
              for ruleset_alias, rule_ids in exception.rules :
              local.waf_ruleset_ids[ruleset_alias] => rule_ids
            }
          } : {},
          length(exception.rulesets) > 0 ? {
            rulesets = [
              for ruleset_alias in exception.rulesets :
              local.waf_ruleset_ids[ruleset_alias]
            ]
          } : {}
        )
      },
      try(exception.description, null) != null ? { description = exception.description } : {},
      try(exception.logging, null) != null ? { logging = exception.logging } : {}
    )
    if var.waf.enabled
  ]

  waf_cloudflare_managed_rule_overrides = merge(
    length(var.waf.managed_rules.cloudflare_managed.rule_overrides) > 0 ? {
      rules = var.waf.managed_rules.cloudflare_managed.rule_overrides
    } : {},
    length(var.waf.managed_rules.cloudflare_managed.category_overrides) > 0 ? {
      categories = var.waf.managed_rules.cloudflare_managed.category_overrides
    } : {}
  )

  waf_cloudflare_managed_rules = var.waf.enabled && var.waf.managed_rules.cloudflare_managed.enabled ? [
    merge(
      {
        action = "execute"
        expression = trimspace(var.waf.managed_rules.cloudflare_managed.expression) != "" ? (
          "(${local.waf_scope_expression}) and (${var.waf.managed_rules.cloudflare_managed.expression})"
        ) : local.waf_scope_expression
        ref     = var.waf.managed_rules.cloudflare_managed.ref
        enabled = true
        action_parameters = merge(
          { id = local.waf_ruleset_ids.cloudflare_managed },
          length(keys(local.waf_cloudflare_managed_rule_overrides)) > 0 ? {
            overrides = local.waf_cloudflare_managed_rule_overrides
          } : {}
        )
      },
      var.waf.managed_rules.cloudflare_managed.description != "" ? { description = var.waf.managed_rules.cloudflare_managed.description } : {},
      try(var.waf.managed_rules.cloudflare_managed.logging, null) != null ? { logging = var.waf.managed_rules.cloudflare_managed.logging } : {}
    )
  ] : []

  # Cloudflare Free Managed Ruleset: same request phase and execute shape as the
  # Cloudflare Managed Ruleset above; only the ruleset ID and inputs differ.
  waf_cloudflare_free_rule_overrides = merge(
    length(var.waf.managed_rules.cloudflare_free.rule_overrides) > 0 ? {
      rules = var.waf.managed_rules.cloudflare_free.rule_overrides
    } : {},
    length(var.waf.managed_rules.cloudflare_free.category_overrides) > 0 ? {
      categories = var.waf.managed_rules.cloudflare_free.category_overrides
    } : {}
  )

  waf_cloudflare_free_rules = var.waf.enabled && var.waf.managed_rules.cloudflare_free.enabled ? [
    merge(
      {
        action = "execute"
        expression = trimspace(var.waf.managed_rules.cloudflare_free.expression) != "" ? (
          "(${local.waf_scope_expression}) and (${var.waf.managed_rules.cloudflare_free.expression})"
        ) : local.waf_scope_expression
        ref     = var.waf.managed_rules.cloudflare_free.ref
        enabled = true
        action_parameters = merge(
          { id = local.waf_ruleset_ids.cloudflare_free },
          length(keys(local.waf_cloudflare_free_rule_overrides)) > 0 ? {
            overrides = local.waf_cloudflare_free_rule_overrides
          } : {}
        )
      },
      var.waf.managed_rules.cloudflare_free.description != "" ? { description = var.waf.managed_rules.cloudflare_free.description } : {},
      try(var.waf.managed_rules.cloudflare_free.logging, null) != null ? { logging = var.waf.managed_rules.cloudflare_free.logging } : {}
    )
  ] : []

  waf_owasp_category_overrides = concat(
    [
      for category in local.waf_owasp_disabled_categories_by_paranoia_level[var.waf.managed_rules.owasp.paranoia_level] : {
        category = category
        enabled  = false
      }
    ],
    var.waf.managed_rules.owasp.category_overrides
  )
  waf_owasp_rule_overrides = concat(
    [
      {
        id              = local.waf_owasp_score_rule_id
        action          = var.waf.managed_rules.owasp.action
        score_threshold = var.waf.managed_rules.owasp.score_threshold
      }
    ],
    var.waf.managed_rules.owasp.rule_overrides
  )

  waf_owasp_rules = var.waf.enabled && var.waf.managed_rules.owasp.enabled ? [
    merge(
      {
        action = "execute"
        expression = trimspace(var.waf.managed_rules.owasp.expression) != "" ? (
          "(${local.waf_scope_expression}) and (${var.waf.managed_rules.owasp.expression})"
        ) : local.waf_scope_expression
        ref     = var.waf.managed_rules.owasp.ref
        enabled = true
        action_parameters = {
          id = local.waf_ruleset_ids.owasp
          overrides = merge(
            length(local.waf_owasp_category_overrides) > 0 ? {
              categories = local.waf_owasp_category_overrides
            } : {},
            length(local.waf_owasp_rule_overrides) > 0 ? {
              rules = local.waf_owasp_rule_overrides
            } : {}
          )
        }
      },
      var.waf.managed_rules.owasp.description != "" ? { description = var.waf.managed_rules.owasp.description } : {},
      try(var.waf.managed_rules.owasp.logging, null) != null ? { logging = var.waf.managed_rules.owasp.logging } : {}
    )
  ] : []

  # Cloudflare Sensitive Data Detection: executes like the managed rulesets above
  # but in the http_response_firewall_managed phase (see waf_managed_response_rules
  # and the managed_response_waf resource). Enterprise only; its rules log only.
  waf_sensitive_data_detection_rule_overrides = merge(
    length(var.waf.managed_rules.sensitive_data_detection.rule_overrides) > 0 ? {
      rules = var.waf.managed_rules.sensitive_data_detection.rule_overrides
    } : {},
    length(var.waf.managed_rules.sensitive_data_detection.category_overrides) > 0 ? {
      categories = var.waf.managed_rules.sensitive_data_detection.category_overrides
    } : {}
  )

  waf_sensitive_data_detection_rules = var.waf.enabled && var.waf.managed_rules.sensitive_data_detection.enabled ? [
    merge(
      {
        action = "execute"
        expression = trimspace(var.waf.managed_rules.sensitive_data_detection.expression) != "" ? (
          "(${local.waf_scope_expression}) and (${var.waf.managed_rules.sensitive_data_detection.expression})"
        ) : local.waf_scope_expression
        ref     = var.waf.managed_rules.sensitive_data_detection.ref
        enabled = true
        action_parameters = merge(
          { id = local.waf_ruleset_ids.sensitive_data_detection },
          length(keys(local.waf_sensitive_data_detection_rule_overrides)) > 0 ? {
            overrides = local.waf_sensitive_data_detection_rule_overrides
          } : {}
        )
      },
      var.waf.managed_rules.sensitive_data_detection.description != "" ? { description = var.waf.managed_rules.sensitive_data_detection.description } : {},
      try(var.waf.managed_rules.sensitive_data_detection.logging, null) != null ? { logging = var.waf.managed_rules.sensitive_data_detection.logging } : {}
    )
  ] : []

  # waf.advanced: native Cloudflare rule objects passed through
  # verbatim, with only the hostname scope ANDed onto each expression so they
  # cannot escape the managed hostnames. Everything else (action,
  # action_parameters, ratelimit, ref, ...) is the caller's exact provider
  # shape. Typed as `any`, so building them as tuples (not list(object)) keeps
  # heterogeneous shapes from tripping Terraform list-unification before they
  # reach the provider.
  waf_advanced_custom_rules = [
    for rule in var.waf.advanced.custom : merge(rule, {
      expression = trimspace(try(rule.expression, "")) != "" ? (
        "(${local.waf_scope_expression}) and (${rule.expression})"
      ) : local.waf_scope_expression
    })
    if var.waf.enabled
  ]

  waf_advanced_managed_rules = [
    for rule in var.waf.advanced.managed : merge(rule, {
      expression = trimspace(try(rule.expression, "")) != "" ? (
        "(${local.waf_scope_expression}) and (${rule.expression})"
      ) : local.waf_scope_expression
    })
    if var.waf.enabled
  ]

  waf_advanced_managed_response_rules = [
    for rule in var.waf.advanced.managed_response : merge(rule, {
      expression = trimspace(try(rule.expression, "")) != "" ? (
        "(${local.waf_scope_expression}) and (${rule.expression})"
      ) : local.waf_scope_expression
    })
    if var.waf.enabled
  ]

  waf_advanced_rate_limit_rules = [
    for rule in var.waf.advanced.rate_limit : merge(rule, {
      expression = trimspace(try(rule.expression, "")) != "" ? (
        "(${local.waf_scope_expression}) and (${rule.expression})"
      ) : local.waf_scope_expression
    })
    if var.waf.enabled
  ]

  waf_managed_rules = concat(
    local.waf_managed_rule_exceptions,
    local.waf_cloudflare_managed_rules,
    local.waf_owasp_rules,
    local.waf_cloudflare_free_rules,
    local.waf_advanced_managed_rules
  )

  # Response-phase managed rules (http_response_firewall_managed). Sensitive Data
  # Detection is the only typed entry; advanced.managed_response appends native
  # response-phase rules. Kept separate from waf_managed_rules because that phase
  # cannot block, only log.
  waf_managed_response_rules = concat(
    local.waf_sensitive_data_detection_rules,
    local.waf_advanced_managed_response_rules
  )

  # First-class IP allow/block lists, synthesized as custom rules so callers
  # never hand-write ip.src expressions. ip_blocklist denies the listed sources;
  # ip_allowlist is default-deny (blocks everything outside the set). Both
  # evaluate before user custom_rules.
  waf_ip_blocklist_rules = var.waf.enabled && length(var.waf.ip_blocklist) > 0 ? [
    {
      action      = "block"
      ref         = "ip_blocklist"
      enabled     = true
      description = "Block source IPs in waf.ip_blocklist"
      expression  = "(${local.waf_scope_expression}) and (ip.src in {${join(" ", var.waf.ip_blocklist)}})"
    }
  ] : []

  waf_ip_allowlist_rules = var.waf.enabled && length(var.waf.ip_allowlist) > 0 ? [
    {
      action      = "block"
      ref         = "ip_allowlist"
      enabled     = true
      description = "Block source IPs not in waf.ip_allowlist (default deny)"
      expression  = "(${local.waf_scope_expression}) and (not (ip.src in {${join(" ", var.waf.ip_allowlist)}}))"
    }
  ] : []

  waf_custom_rules = concat(
    local.waf_ip_blocklist_rules,
    local.waf_ip_allowlist_rules,
    [
      for rule in var.waf.custom_rules : merge(
        {
          action = rule.action
          expression = trimspace(try(rule.expression, "")) != "" ? (
            "(${local.waf_scope_expression}) and (${rule.expression})"
          ) : local.waf_scope_expression
          ref     = rule.ref
          enabled = try(rule.enabled, true)
        },
        try(rule.description, null) != null ? { description = rule.description } : {},
        # A skip rule needs action_parameters; default to skipping the rest of
        # the current ruleset. Advanced skip targets and any other
        # action_parameters go through waf.advanced.custom.
        rule.action == "skip" ? { action_parameters = { ruleset = "current" } } : {},
        try(rule.logging, null) != null ? { logging = rule.logging } : {}
      )
      if var.waf.enabled
    ],
    local.waf_advanced_custom_rules
  )

  waf_rate_limit_rules = concat(
    [
      for rule in var.waf.rate_limit_rules : merge(
        {
          action = rule.action
          expression = trimspace(try(rule.expression, "")) != "" ? (
            "(${local.waf_scope_expression}) and (${rule.expression})"
          ) : local.waf_scope_expression
          ref     = rule.ref
          enabled = try(rule.enabled, true)
          ratelimit = merge(
            {
              characteristics = rule.characteristics
              period          = rule.period
            },
            try(rule.counting_expression, null) != null ? { counting_expression = rule.counting_expression } : {},
            try(rule.mitigation_timeout, null) != null ? { mitigation_timeout = rule.mitigation_timeout } : {},
            try(rule.requests_per_period, null) != null ? { requests_per_period = rule.requests_per_period } : {},
            try(rule.requests_to_origin, null) != null ? { requests_to_origin = rule.requests_to_origin } : {},
            try(rule.score_per_period, null) != null ? { score_per_period = rule.score_per_period } : {},
            try(rule.score_response_header_name, null) != null ? { score_response_header_name = rule.score_response_header_name } : {}
          )
        },
        try(rule.description, null) != null ? { description = rule.description } : {},
        try(rule.logging, null) != null ? { logging = rule.logging } : {}
      )
      if var.waf.enabled
    ],
    local.waf_advanced_rate_limit_rules
  )
}

resource "cloudflare_ruleset" "managed_waf" {
  count = length(local.waf_managed_rules) > 0 ? 1 : 0

  zone_id     = var.zone_id
  name        = "${local.ruleset_name_prefix} managed WAF"
  description = "Managed WAF entry-point ruleset managed by this Terraform module."
  kind        = "zone"
  phase       = "http_request_firewall_managed"
  rules       = local.waf_managed_rules
}

resource "cloudflare_ruleset" "managed_response_waf" {
  count = length(local.waf_managed_response_rules) > 0 ? 1 : 0

  zone_id     = var.zone_id
  name        = "${local.ruleset_name_prefix} managed response WAF"
  description = "Managed response WAF entry-point ruleset managed by this Terraform module."
  kind        = "zone"
  phase       = "http_response_firewall_managed"
  rules       = local.waf_managed_response_rules
}

resource "cloudflare_ruleset" "custom_waf" {
  count = length(local.waf_custom_rules) > 0 ? 1 : 0

  zone_id     = var.zone_id
  name        = "${local.ruleset_name_prefix} custom WAF"
  description = "Custom WAF entry-point ruleset managed by this Terraform module."
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  rules       = local.waf_custom_rules
}

resource "cloudflare_ruleset" "rate_limit" {
  count = length(local.waf_rate_limit_rules) > 0 ? 1 : 0

  zone_id     = var.zone_id
  name        = "${local.ruleset_name_prefix} rate limits"
  description = "Rate limiting entry-point ruleset managed by this Terraform module."
  kind        = "zone"
  phase       = "http_ratelimit"
  rules       = local.waf_rate_limit_rules
}

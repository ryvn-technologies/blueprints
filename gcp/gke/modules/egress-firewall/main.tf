resource "google_project_service" "network_security" {
  project            = var.project_id
  service            = "networksecurity.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "certificate_authority" {
  project            = var.project_id
  service            = "privateca.googleapis.com"
  disable_on_destroy = false
}

resource "terraform_data" "contract" {
  lifecycle {
    precondition {
      condition     = length(local.priorities) == length(distinct(local.priorities))
      error_message = "Stable firewall priority hash collision; rename one policy rule or source class."
    }
    precondition {
      condition     = alltrue([for p in values(local.url_profiles) : length(p.domains) <= 2499])
      error_message = "Cloud NGFW supports 2500 URL matcher strings per profile (one reserved for final deny); reduce this class's domain list."
    }
  }
}

resource "google_compute_network_firewall_policy" "egress" {
  name        = local.resource_name
  description = "Default-deny egress with native Cloud NGFW URL inspection"
  project     = var.project_id
}

# The graph associates final deny rules before installing web inspection rules.
# Endpoint and association postconditions check API state, not traffic behavior.
resource "google_compute_network_firewall_policy_rule" "deny" {
  firewall_policy = google_compute_network_firewall_policy.egress.name
  project         = var.project_id
  priority        = local.firewall_deny_priority
  rule_name       = "deny-egress"
  direction       = "EGRESS"
  action          = "deny"
  enable_logging  = true
  match {
    src_ip_ranges  = local.firewall_default_deny_rule.sources
    dest_ip_ranges = local.firewall_default_deny_rule.destinations
    layer4_configs { ip_protocol = "all" }
  }
}

resource "google_compute_network_firewall_policy_rule" "deny_ipv6" {
  firewall_policy = google_compute_network_firewall_policy.egress.name
  project         = var.project_id
  priority        = local.firewall_default_deny_ipv6_rule.priority
  rule_name       = "deny-egress-ipv6"
  direction       = "EGRESS"
  action          = "deny"
  enable_logging  = true
  match {
    src_ip_ranges  = local.firewall_default_deny_ipv6_rule.sources
    dest_ip_ranges = local.firewall_default_deny_ipv6_rule.destinations
    layer4_configs { ip_protocol = "all" }
  }
}

resource "google_compute_network_firewall_policy_association" "egress" {
  name              = local.resource_name
  project           = var.project_id
  firewall_policy   = google_compute_network_firewall_policy.egress.name
  attachment_target = var.network_id
  depends_on        = [google_compute_network_firewall_policy_rule.deny, google_compute_network_firewall_policy_rule.deny_ipv6]
}

resource "google_network_security_firewall_endpoint" "egress" {
  for_each           = var.zones
  name               = local.resource_name
  parent             = "projects/${var.project_id}"
  location           = each.key
  billing_project_id = var.project_id
  depends_on         = [google_project_service.network_security, google_project_service.certificate_authority, google_compute_network_firewall_policy_association.egress]
  lifecycle {
    postcondition {
      condition     = self.state == "ACTIVE" && !self.reconciling
      error_message = "Firewall endpoint is not ACTIVE; no inspection permits will be installed."
    }
  }
}

resource "google_network_security_firewall_endpoint_association" "egress" {
  for_each          = var.zones
  name              = local.resource_name
  parent            = "projects/${var.project_id}"
  location          = each.key
  network           = var.network_id
  firewall_endpoint = google_network_security_firewall_endpoint.egress[each.key].id
  lifecycle {
    postcondition {
      condition     = self.state == "ACTIVE" && !self.reconciling
      error_message = "Firewall endpoint association is not ACTIVE; no inspection permits will be installed."
    }
  }
}

resource "google_network_security_security_profile" "web" {
  for_each    = local.url_profiles
  name        = "${local.resource_name}-${substr(sha256(each.key), 0, 12)}"
  parent      = "projects/${var.project_id}"
  location    = "global"
  description = "Native URL allowlist for ${each.key}; Host or visible TLS SNI, not TLS-only enforcement"
  type        = "URL_FILTERING"
  url_filtering_profile {
    dynamic "url_filters" {
      for_each = each.value.filters
      content {
        priority         = url_filters.value.priority
        filtering_action = url_filters.value.action
        urls             = url_filters.value.urls
      }
    }
  }
  depends_on = [google_project_service.network_security, terraform_data.contract]
}

resource "google_network_security_security_profile_group" "web" {
  for_each              = local.url_profiles
  name                  = "${local.resource_name}-${substr(sha256(each.key), 0, 12)}"
  parent                = "projects/${var.project_id}"
  location              = "global"
  url_filtering_profile = google_network_security_security_profile.web[each.key].id
}

resource "google_compute_network_firewall_policy_rule" "direct" {
  for_each        = local.direct_rules
  firewall_policy = google_compute_network_firewall_policy.egress.name
  project         = var.project_id
  priority        = each.value.priority
  rule_name       = "direct-${substr(sha256(each.key), 0, 12)}"
  direction       = "EGRESS"
  action          = each.value.action
  enable_logging  = true
  match {
    src_ip_ranges  = each.value.sources
    dest_ip_ranges = each.value.destinations
    dynamic "layer4_configs" {
      for_each = each.value.layer4
      content {
        ip_protocol = layer4_configs.value.ip_protocol
        ports       = length(layer4_configs.value.ports) > 0 ? layer4_configs.value.ports : null
      }
    }
  }
  depends_on = [google_compute_network_firewall_policy_association.egress, terraform_data.contract]
}

resource "google_compute_network_firewall_policy_rule" "inspect" {
  for_each               = local.inspection_rules
  firewall_policy        = google_compute_network_firewall_policy.egress.name
  project                = var.project_id
  priority               = each.value.priority
  rule_name              = "inspect-${substr(sha256(each.key), 0, 12)}"
  direction              = "EGRESS"
  action                 = each.value.action
  security_profile_group = "//networksecurity.googleapis.com/${google_network_security_security_profile_group.web[each.key].id}"
  tls_inspect            = false
  enable_logging         = true
  match {
    src_ip_ranges        = each.value.sources
    dest_ip_ranges       = each.value.destinations
    dest_network_context = each.value.destination_context
    layer4_configs {
      ip_protocol = "tcp"
      ports       = each.value.layer4[0].ports
    }
  }
  depends_on = [google_network_security_firewall_endpoint_association.egress, google_compute_network_firewall_policy_rule.direct]
}

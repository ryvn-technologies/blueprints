locals {
  effective_rule_defaults = {
    class                    = null, policy_key = null, rule_key = null, origin = null, domain = null
    protocol                 = null, destination_port = null, sources = null, profile_key = null
    bypasses_domain_matching = null, destinations = null, ports = null, reason = null
    firewall_rule            = null, priority = null, url_profile = null, mechanism = null, tls_only = null
  }
  readiness = {
    ready             = alltrue([for e in google_network_security_firewall_endpoint.egress : e.state == "ACTIVE" && !e.reconciling]) && alltrue([for a in google_network_security_firewall_endpoint_association.egress : a.state == "ACTIVE" && !a.reconciling])
    zones             = sort(tolist(var.zones))
    endpoints         = { for zone, e in google_network_security_firewall_endpoint.egress : zone => { id = e.id, state = e.state, reconciling = e.reconciling } }
    associations      = { for zone, a in google_network_security_firewall_endpoint_association.egress : zone => { id = a.id, state = a.state, reconciling = a.reconciling } }
    traffic_validated = false
  }
}
output "readiness" {
  value      = local.readiness
  depends_on = [google_compute_network_firewall_policy_rule.inspect, google_compute_network_firewall_policy_rule.direct]
}
output "effective_rules" {
  value = merge(
    { for key, r in local.domain_rules : key => merge(local.effective_rule_defaults, r, {
      firewall_rule = google_compute_network_firewall_policy_rule.inspect[r.profile_key].id
      priority      = local.inspection_rules[r.profile_key].priority
      url_profile   = google_network_security_security_profile.web[r.profile_key].id
      mechanism     = "native-url-filter", tls_only = false
    }) },
    { for key, r in local.network_rules : key => merge(local.effective_rule_defaults, r, {
      firewall_rule = google_compute_network_firewall_policy_rule.direct[key].id
      priority      = local.firewall_network_rules[key].priority, mechanism = "exact-l4-tuple"
    }) },
  )
}
output "compiled_policy" {
  value = { url_profiles = local.url_profiles, direct_rules = local.direct_rules, inspection_rules = local.inspection_rules, final_deny = local.firewall_default_deny_rule, final_deny_ipv6 = local.firewall_default_deny_ipv6_rule }
}
output "enforcement_refs" {
  value = {
    policy                = google_compute_network_firewall_policy.egress.id
    association           = google_compute_network_firewall_policy_association.egress.id
    endpoints             = { for zone, e in google_network_security_firewall_endpoint.egress : zone => e.id }
    endpoint_associations = { for zone, a in google_network_security_firewall_endpoint_association.egress : zone => a.id }
    url_profiles          = { for key, p in google_network_security_security_profile.web : key => p.id }
    profile_groups        = { for key, p in google_network_security_security_profile_group.web : key => p.id }
  }
}
output "capabilities" {
  value = {
    implementation                           = "cloud-ngfw-enterprise-url-filtering"
    exact_and_native_wildcard_domains        = true
    source_and_port_isolation                = true
    https_only_enforced                      = false
    missing_domain_default_deny_enforced     = false
    non_http_tcp80_443_default_deny_enforced = false
    inspection_fail_closed_enforced          = false
    destination_ownership_authenticated      = false
    tls_decryption                           = false
    explicit_proxy                           = false
    live_validated                           = false
    uncovered_zone_can_bypass_inspection     = true
    optional_swp_hook                        = "Compose an additive web layer separately; no SWP resources or L4 bypass installed."
  }
}
output "exclusions" {
  value = [
    "Plaintext HTTP with an allowed Host can pass TCP443; destination port is not TLS-only enforcement.",
    "Controlled native tests delivered missing/empty-Host HTTP80, missing-Host HTTP443, CONNECT, malformed/partial HTTP and raw TCP443 despite the final URL DENY; this is not application-aware default drop.",
    "HTTPS uses visible SNI without decrypting TLS or authenticating destination ownership; ECH/ESNI is not supported.",
    "QUIC/UDP443 has no domain inspection and is denied; explicit UDP443 tuples are rejected by the root contract.",
    "Direct network_allow tuples intentionally bypass domain matching, including explicit web-port exceptions.",
    "Internal VPC ranges bypass URL inspection; metadata/link-local is platform traffic outside this firewall's contract.",
    "Google documents inspection bypass in zones without an associated endpoint; all workload zones must be declared and associations retained.",
    "Controlled association-loss tests delivered denied Host/SNI from declared and undeclared zones; endpoint health is not a runtime fail-closed guarantee.",
    "API readiness is not traffic validation or a full parity claim; deployment-specific lifecycle and enforcement require correlated live evidence.",
  ]
}
output "log_refs" {
  value = {
    firewall      = "logName=\"projects/${var.project_id}/logs/compute.googleapis.com%2Ffirewall\""
    url_filtering = "logName=\"projects/${var.project_id}/logs/networksecurity.googleapis.com%2Ffirewall_url_filter\""
    policy        = google_compute_network_firewall_policy.egress.id
  }
}

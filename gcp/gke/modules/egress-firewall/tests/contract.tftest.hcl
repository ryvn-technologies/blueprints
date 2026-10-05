mock_provider "google" {
  mock_resource "google_network_security_firewall_endpoint" {
    defaults = { state = "ACTIVE", reconciling = false }
  }
  mock_resource "google_network_security_firewall_endpoint_association" {
    defaults = { state = "ACTIVE", reconciling = false }
  }
}

variables {
  name                       = "test"
  project_id                 = "test-project"
  network_id                 = "projects/test-project/global/networks/test"
  zones                      = ["us-central1-a", "us-central1-b"]
  internal_destination_cidrs = ["10.0.0.0/24"]
  classes = {
    cluster = { policy_key = "cluster", sources = ["10.0.0.0/24", "10.1.0.0/24"] }
    worker  = { policy_key = "worker", sources = ["10.2.0.0/24"] }
  }
  platform_https_domains = ["platform.example.com"]
  policies = {
    cluster = {
      domain_allow = {
        vendor = { domains = ["api.example.com", "*.example.org"], protocol = "https" }
        mirror = { domains = ["mirror.example.com"], protocol = "http" }
      }
      network_allow = {
        tcp = { destination_ipv4_cidrs = ["8.8.8.8/32"], protocol = "tcp", destination_ports = [443, 8443], reason = "Intentional web exception" }
        udp = { destination_ipv4_cidrs = ["9.9.9.9/32"], protocol = "udp", destination_ports = [51820], reason = "Controlled tuple" }
      }
    }
    worker = {
      domain_allow  = { vendor = { domains = ["api.example.com"], protocol = "https" } }
      network_allow = {}
    }
  }
}

run "native_url_profiles_are_class_and_port_scoped" {
  command = plan
  assert {
    condition     = google_project_service.certificate_authority.service == "privateca.googleapis.com" && !google_project_service.certificate_authority.disable_on_destroy && !google_project_service.network_security.disable_on_destroy
    error_message = "Native endpoint prerequisite APIs must be enabled and never disabled by teardown."
  }
  assert {
    condition     = toset(local.url_profiles["cluster/https"].domains) == toset(["api.example.com", "*.example.org", "platform.example.com"]) && toset(local.url_profiles["worker/https"].domains) == toset(["api.example.com"])
    error_message = "Platform domains must join cluster HTTPS only, without wildcard expansion or FQDN selectors."
  }
  assert {
    condition     = toset(local.url_profiles["cluster/http"].domains) == toset(["mirror.example.com"]) && length(local.url_profiles["worker/http"].domains) == 0
    error_message = "HTTP and HTTPS profile permissions must not leak between protocols or classes."
  }
  assert {
    condition     = alltrue([for p in values(local.url_profiles) : p.filters["deny"].urls == ["*"] && p.filters["deny"].action == "DENY"])
    error_message = "Every profile, including empty ones, needs final URL DENY."
  }
  assert {
    condition     = alltrue([for r in values(local.inspection_rules) : r.action == "apply_security_profile_group" && r.destinations == ["0.0.0.0/0"] && r.destination_context == null && length(r.layer4) == 1 && r.layer4[0].ip_protocol == "tcp" && length(r.layer4[0].ports) == 1])
    error_message = "Web paths, including NON_INTERNET global Google APIs, must use URL inspection, never broad L4 allows or destination FQDN objects."
  }
}

run "tuples_precede_inspection_and_stay_exact" {
  command = plan
  assert {
    condition     = alltrue([for r in values(local.firewall_network_rules) : r.priority > local.firewall_internal_priority && r.priority < local.firewall_inspection_band && r.action == "allow"]) && local.firewall_inspection_band + 268435455 < local.firewall_deny_priority
    error_message = "Disjoint priority bands must be internal, exact exceptions, inspection, final deny."
  }
  assert {
    condition     = local.firewall_network_rules["cluster/network/tcp"].layer4[0].ports == ["443", "8443"] && local.firewall_network_rules["cluster/network/udp"].layer4[0].ports == ["51820"] && local.firewall_network_rules["cluster/network/udp"].layer4[0].ip_protocol == "udp"
    error_message = "Tuple rules must preserve protocol and exact ports, not CIDR-wide direct routing."
  }
  assert {
    condition     = local.firewall_default_deny_rule.action == "deny" && local.firewall_default_deny_rule.destinations == ["0.0.0.0/0"] && local.firewall_default_deny_rule.sources == ["0.0.0.0/0"] && local.firewall_default_deny_ipv6_rule.action == "deny" && local.firewall_default_deny_ipv6_rule.sources == ["::/0"] && local.firewall_default_deny_ipv6_rule.destinations == ["::/0"]
    error_message = "Final policy rules must explicitly deny unmatched IPv4 and IPv6 traffic."
  }
  assert {
    condition     = toset(google_compute_network_firewall_policy_rule.deny.match[0].src_ip_ranges) == toset(["0.0.0.0/0"]) && toset(google_compute_network_firewall_policy_rule.deny_ipv6.match[0].src_ip_ranges) == toset(["::/0"]) && google_compute_network_firewall_policy_rule.deny_ipv6.priority > google_compute_network_firewall_policy_rule.deny.priority
    error_message = "Native deny rules must keep IPv4 and IPv6 separate at distinct final priorities."
  }
  assert {
    condition     = output.effective_rules["cluster/network/tcp"].bypasses_domain_matching && !output.effective_rules["cluster/domain/vendor/https/443/api.example.com"].bypasses_domain_matching && !output.capabilities.https_only_enforced && !output.capabilities.destination_ownership_authenticated && !output.capabilities.missing_domain_default_deny_enforced && !output.capabilities.non_http_tcp80_443_default_deny_enforced && !output.capabilities.inspection_fail_closed_enforced
    error_message = "Observable metadata must distinguish tuple bypass and known protocol/ownership limits."
  }
}

run "unready_endpoint_blocks_activation" {
  command = plan
  override_resource {
    target          = google_network_security_firewall_endpoint.egress["us-central1-a"]
    override_during = plan
    values          = { state = "CREATING", reconciling = true }
  }
  expect_failures = [google_network_security_firewall_endpoint.egress["us-central1-a"]]
}

run "unready_association_rejects_api_readiness" {
  command = plan
  override_resource {
    target          = google_network_security_firewall_endpoint_association.egress["us-central1-a"]
    override_during = plan
    values          = { state = "CREATING", reconciling = true }
  }
  expect_failures = [google_network_security_firewall_endpoint_association.egress["us-central1-a"]]
}

run "endpoint_coverage_and_readiness" {
  command = apply
  assert {
    condition     = length(google_network_security_firewall_endpoint.egress) == 2 && length(google_network_security_firewall_endpoint_association.egress) == 2 && output.readiness.ready
    error_message = "Every workload zone needs an ACTIVE endpoint and association before readiness."
  }
  assert {
    condition     = !output.readiness.traffic_validated && !output.capabilities.live_validated && !output.capabilities.inspection_fail_closed_enforced
    error_message = "ACTIVE API resources must not publish traffic validation or runtime fail-closed guarantees."
  }
  assert {
    condition     = alltrue([for e in google_network_security_firewall_endpoint.egress : e.parent == "projects/test-project"]) && alltrue([for p in google_network_security_security_profile.web : p.parent == "projects/test-project"]) && length(output.enforcement_refs.url_profiles) == 4
    error_message = "All endpoints/profiles must be project scoped and every class/protocol must have a profile."
  }
}

run "zone_required" {
  command = plan
  variables { zones = [] }
  expect_failures = [var.zones]
}

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      client_id       = "00000000-0000-0000-0000-000000000001"
      object_id       = "00000000-0000-0000-0000-000000000002"
      subscription_id = "00000000-0000-0000-0000-000000000003"
      tenant_id       = "00000000-0000-0000-0000-000000000004"
    }
  }
  mock_data "azurerm_subscription" {
    defaults = {
      id              = "/subscriptions/00000000-0000-0000-0000-000000000003"
      subscription_id = "00000000-0000-0000-0000-000000000003"
      tenant_id       = "00000000-0000-0000-0000-000000000004"
    }
  }
}
mock_provider "azapi" {}
mock_provider "local" {}
mock_provider "null" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  environment_name       = "egress-contract"
  location               = "eastus2"
  public_root_domain     = "test.example.com"
  internal_root_domain   = "test.internal"
  zones                  = ["1"]
  platform_https_domains = ["api.dedicated.example", "loki.dedicated.example"]
  egress_firewall = {
    enabled = true
    policies = {
      cluster = { domain_allow = {
        vendor = { domains = ["api.vendor.example", "*.vendor.example"], protocol = "https" }
        mirror = { domains = ["mirror.example"], protocol = "http", destination_ports = [80] }
      } }
    }
  }
  additional_subnet_groups = [{ name = "api_clients", ipv4_prefix_length = 26 }]
  egress_attachments       = { workers = { subnet_group_key = "api_clients", policy_key = "cluster" } }
}

run "named_rules_and_platform_isolation" {
  command = plan
  assert {
    condition     = length([for r in output.egress_firewall.effective_rules : r if r.id == "cluster-customer-vendor" && length(r.ports) == 1 && contains(r.ports, 443) && toset(r.destinations) == toset(["*.vendor.example", "api.vendor.example"])]) == 1
    error_message = "The named HTTPS rule must retain its identity, domains and port."
  }
  assert {
    condition     = length([for r in output.egress_firewall.effective_rules : r if r.id == "cluster-customer-mirror" && length(r.ports) == 1 && contains(r.ports, 80)]) == 1
    error_message = "The named HTTP rule must retain its explicit port."
  }
  assert {
    condition     = length([for r in output.egress_firewall.effective_rules : r if r.class == "cluster" && r.source == "platform-cluster" && contains(r.destinations, "api.dedicated.example")]) == 1 && length([for r in output.egress_firewall.effective_rules : r if r.class == "workers" && contains(r.destinations, "api.dedicated.example")]) == 0
    error_message = "The dedicated hub baseline is cluster-only, even when the external class shares a policy key."
  }
}

run "reject_unsupported_protocol_and_ports" {
  command = plan
  variables {
    egress_firewall = { enabled = true, policies = { cluster = { domain_allow = { bad = { domains = ["api.vendor.example"], protocol = "https", destination_ports = [8443] } } } } }
  }
  expect_failures = [var.egress_firewall]
}

run "reject_empty_explicit_ports" {
  command = plan
  variables {
    egress_firewall = { enabled = true, policies = { cluster = { domain_allow = { bad = { domains = ["api.vendor.example"], protocol = "https", destination_ports = [] } } } } }
  }
  expect_failures = [var.egress_firewall]
}

run "managed_artifacts_are_cluster_only" {
  command = plan
  assert {
    condition = alltrue([
      for host in [
        "index.docker.io", "docker.io", "registry-1.docker.io", "auth.docker.io",
        "production.cloudflare.docker.com", "production.cloudfront.docker.com",
        "docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com",
        "charts.ryvn.app", "registry.ryvn.app", "ghcr.io", "pkg-containers.githubusercontent.com",
        "registry.k8s.io", "cdn.registry.k8s.io", "registry.istio.io", "gcr.io", "*.pkg.dev",
        "quay.io", "*.quay.io", "acme-v02.api.letsencrypt.org",
        ] : length([
          for rule in output.egress_firewall.effective_rules : rule
          if rule.class == "cluster" && rule.source == "platform-cluster" && rule.action == "Allow" &&
          contains(rule.destinations, host) && toset(rule.ports) == toset([443]) && rule.protocol == "tcp"
      ]) == 1
    ])
    error_message = "Managed chart, token, image and blob endpoints must compile as cluster HTTPS/443 allowances."
  }
  assert {
    condition = alltrue([
      for rule in output.egress_firewall.effective_rules : rule.class != "workers" || rule.source != "platform-cluster"
      ]) && toset(flatten([
        for rule in output.egress_firewall.effective_rules : rule.destinations if rule.class == "workers" && rule.action == "Allow"
    ])) == toset(["api.vendor.example", "*.vendor.example", "mirror.example"])
    error_message = "A VM sharing cluster_policy_key must receive exactly its customer domains, never registry or hub defaults."
  }
}

run "baseline_excludes_public_ntp_and_unreviewed_cloud_permits" {
  command = plan
  assert {
    condition = alltrue([
      for rule in output.egress_firewall.effective_rules :
      !(rule.source == "platform-cluster" && rule.action == "Allow" && rule.protocol == "udp" && contains(rule.ports, 123))
    ])
    error_message = "Modern AKS platform time must not create an unconditional public UDP/123 allowance."
  }
  assert {
    condition = length(setintersection(toset(flatten([
      for rule in output.egress_firewall.effective_rules : rule.destinations if rule.action == "Allow"
      ])), toset([
      "*", "0.0.0.0/0", "*.amazonaws.com", "*.cloudfront.net", "*.cloudflarestorage.com",
      "ntp.ubuntu.com", "169.254.169.123", "api.anthropic.com", "api.resend.com", "accounts.google.com",
      "*.tailscale.com", "registry.npmjs.org", "ec2.eastus2.amazonaws.com", "eks.eastus2.amazonaws.com",
      "docker-images-prod.s3.dualstack.eastus2.amazonaws.com",
    ]))) == 0
    error_message = "No CDN/cloud wildcard, AWS-only endpoint, public NTP or customer integration may enter Azure's baseline."
  }
  assert {
    condition = length([
      for rule in output.egress_firewall.effective_rules : rule
      if rule.action == "Allow" && rule.protocol == "udp" && (contains(rule.ports, 443) || contains(rule.ports, 3478))
    ]) == 0
    error_message = "QUIC and Tailscale STUN remain denied by default."
  }
}

run "reject_public_suffix_outside_curated_subset" {
  command = plan
  variables {
    egress_firewall = { enabled = true, policies = { cluster = { domain_allow = { bad = { domains = ["*.co.il"], protocol = "https" } } } } }
  }
  expect_failures = [var.egress_firewall]
}

run "reject_regional_cloud_public_suffix" {
  command = plan
  variables {
    egress_firewall = { enabled = true, policies = { cluster = { domain_allow = { bad = { domains = ["*.s3.us-east-1.amazonaws.com"], protocol = "https" } } } } }
  }
  expect_failures = [var.egress_firewall]
}

run "reject_wildcard_public_suffix_rule" {
  command = plan
  variables {
    egress_firewall = { enabled = true, policies = { cluster = { domain_allow = { bad = { domains = ["*.foo.ck"], protocol = "https" } } } } }
  }
  expect_failures = [var.egress_firewall]
}

run "reject_punycode_public_suffix" {
  command = plan
  variables {
    egress_firewall = { enabled = true, policies = { cluster = { domain_allow = { bad = { domains = ["*.xn--55qx5d.cn"], protocol = "https" } } } } }
  }
  expect_failures = [var.egress_firewall]
}

run "reject_azure_hosted_service_suffix" {
  command = plan
  variables {
    egress_firewall = { enabled = true, policies = { cluster = { domain_allow = { bad = { domains = ["*.azure-api.net"], protocol = "https" } } } } }
  }
  expect_failures = [var.egress_firewall]
}

run "allow_psl_exceptions_and_registrable_domains" {
  command = plan
  variables {
    egress_firewall = { enabled = true, policies = { cluster = { domain_allow = {
      valid = { domains = ["*.www.ck", "*.customer.co.il", "*.xn--bcher-kva.example", "xn--80ak6aa92e.xn--55qx5d.cn"], protocol = "https" }
    } } } }
  }
  assert {
    condition = length([
      for rule in output.egress_firewall.effective_rules : rule
      if rule.id == "cluster-customer-valid" && toset(rule.destinations) == toset([
        "*.www.ck", "*.customer.co.il", "*.xn--bcher-kva.example", "xn--80ak6aa92e.xn--55qx5d.cn",
      ])
    ]) == 1
    error_message = "PSL exception rules and registrable ASCII/Punycode domains must still compile."
  }
}

run "reject_test_net_2" {
  command = plan
  variables {
    egress_firewall = { enabled = true, policies = { cluster = { network_allow = {
      documentation = { destination_ipv4_cidrs = ["198.51.100.0/24"], protocol = "tcp", destination_ports = [443], reason = "Reserved documentation ranges are not public endpoints." }
    } } } }
  }
  expect_failures = [var.egress_firewall]
}

run "reject_test_net_3" {
  command = plan
  variables {
    egress_firewall = { enabled = true, policies = { cluster = { network_allow = {
      documentation = { destination_ipv4_cidrs = ["203.0.113.0/24"], protocol = "tcp", destination_ports = [443], reason = "Reserved documentation ranges are not public endpoints." }
    } } } }
  }
  expect_failures = [var.egress_firewall]
}

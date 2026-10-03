mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email  = "ryvn-mock@test-project.iam.gserviceaccount.com"
      member = "serviceAccount:ryvn-mock@test-project.iam.gserviceaccount.com"
      name   = "projects/test-project/serviceAccounts/ryvn-mock@test-project.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_network_security_firewall_endpoint" {
    defaults = { state = "ACTIVE", reconciling = false }
  }
  mock_resource "google_network_security_firewall_endpoint_association" {
    defaults = { state = "ACTIVE", reconciling = false }
  }

  mock_data "google_client_openid_userinfo" {
    defaults = {
      email = "terraform@example.iam.gserviceaccount.com"
    }
  }

  mock_data "google_container_engine_versions" {
    defaults = {
      latest_master_version = "1.37.0-gke.1000000"
      release_channel_default_version = {
        REGULAR = "1.36.3-gke.1640000"
      }
      release_channel_latest_version = {
        REGULAR = "1.36.3-gke.1767000"
      }
    }
  }

  mock_data "google_compute_zones" {
    defaults = {
      names = ["us-central1-a", "us-central1-b", "us-central1-c"]
    }
  }

  mock_resource "google_compute_global_address" {
    defaults = {
      address = "10.21.0.0"
    }
  }

  mock_resource "google_compute_address" {
    defaults = {
      address = "10.0.0.250"
    }
  }
}

mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "random" {}

variables {
  environment          = "eg"
  project_id           = "test-project"
  region               = "us-central1"
  zones                = ["us-central1-a"]
  public_root_domain   = "test.example.com"
  internal_root_domain = "test.internal"

  egress_firewall = {
    enabled            = true
    cluster_policy_key = "cluster"
    policies = {
      cluster = {
        domain_allow = {
          vendor = { domains = ["api.vendor.example", "*.customer.example"], protocol = "https" }
          mirror = { domains = ["mirror.customer.example"], protocol = "http" }
        }
        network_allow = {
          smtp_relay = {
            destination_ipv4_cidrs = ["8.8.8.0/24"]
            protocol               = "tcp"
            destination_ports      = [587]
            reason                 = "Outbound SMTP relay pinned by IP"
          }
          vendor_web = {
            destination_ipv4_cidrs = ["1.1.1.1/32"]
            protocol               = "tcp"
            destination_ports      = [443]
            reason                 = "Deliberate raw TLS to a vendor appliance"
          }
          tunnel = {
            destination_ipv4_cidrs = ["9.9.9.0/24"]
            protocol               = "udp"
            destination_ports      = [51820]
            reason                 = "WireGuard to a partner"
          }
        }
      }
      workers = {
        domain_allow = {
          vendor = { domains = ["api.vendor.example"], protocol = "https" }
        }
      }
    }
  }

  additional_subnet_groups = [
    { name = "api_clients", ipv4_prefix_length = 24 },
    { name = "batch", ipv4_prefix_length = 26 },
  ]
  egress_attachments = {
    api_clients = { subnet_group_key = "api_clients", policy_key = "workers" }
  }
}

# ---------------------------------------------------------------------------
# Disabled / omitted mode
# ---------------------------------------------------------------------------

run "disabled_by_default_preserves_network" {
  command = plan

  variables {
    egress_firewall          = {}
    additional_subnet_groups = []
    egress_attachments       = {}
  }

  assert {
    condition     = length(module.egress_firewall) == 0 && length(google_compute_subnetwork.additional_group) == 0
    error_message = "Omitted egress_firewall must not create inspection endpoints, firewall policy or subnet group resources."
  }

  assert {
    condition     = google_compute_router_nat.nat.source_subnetwork_ip_ranges_to_nat == "ALL_SUBNETWORKS_ALL_IP_RANGES" && google_compute_router_nat.nat.log_config[0].filter == "ERRORS_ONLY"
    error_message = "Disabled mode without groups must keep NAT on every subnet with error-only logging."
  }

  assert {
    condition     = coalesce(module.gcp-network.network.network.network_firewall_policy_enforcement_order, "AFTER_CLASSIC_FIREWALL") == "AFTER_CLASSIC_FIREWALL"
    error_message = "Disabled mode must keep the network's default firewall evaluation order."
  }

  assert {
    condition     = !output.egress_firewall.enabled && length(output.egress_firewall.attachments) == 0 && length(output.egress_firewall.effective_rules) == 0 && length(output.egress_firewall.nat_public_ips) == 0 && length(output.egress_firewall.web_egress_ips) == 0
    error_message = "Disabled mode must publish enabled=false with empty diagnostics."
  }

  assert {
    condition     = length(output.outbound_ips) == 1
    error_message = "Disabled mode keeps the single Cloud NAT address as the outbound IP."
  }
}

run "disabled_mode_rejects_attachments" {
  command = plan

  variables {
    egress_firewall = {}
  }

  expect_failures = [var.egress_attachments]
}

run "null_optional_inputs_preserve_disabled_mode" {
  command = plan
  variables {
    egress_firewall          = null
    additional_subnet_groups = null
    egress_attachments       = null
    platform_https_domains   = null
  }
  assert {
    condition     = !output.egress_firewall.enabled && length(module.egress_firewall) == 0 && length(output.additional_subnet_groups) == 0
    error_message = "Null optional inputs must use the disabled/empty defaults, not force resources or fail evaluation."
  }
}

run "disabled_groups_stay_local_only" {
  command = plan

  variables {
    egress_firewall    = {}
    egress_attachments = {}
  }

  assert {
    condition     = google_compute_router_nat.nat.source_subnetwork_ip_ranges_to_nat == "LIST_OF_SUBNETWORKS" && length(google_compute_router_nat.nat.subnetwork) == 1
    error_message = "With subnet groups, NAT must serve the cluster subnet only."
  }

  assert {
    condition     = output.additional_subnet_groups["api_clients"].ipv4_cidr == "10.0.192.0/24" && output.additional_subnet_groups["batch"].ipv4_cidr == "10.0.193.0/26"
    error_message = "Groups must be allocated in declaration order from additional_subnet_groups_cidr."
  }

  assert {
    condition     = !google_compute_subnetwork.additional_group["api_clients"].private_ip_google_access && google_compute_subnetwork.additional_group["api_clients"].name == "ext-api-clients-eg"
    error_message = "Group subnets must have no Private Google Access and a group-derived name."
  }

  assert {
    condition     = output.additional_subnet_groups["batch"].ipv4_prefix_length == 26 && output.additional_subnet_groups["batch"].region == "us-central1"
    error_message = "additional_subnet_groups must publish network inventory independently of the firewall."
  }
}

# ---------------------------------------------------------------------------
# Enabled: topology
# ---------------------------------------------------------------------------

run "rejects_udp_443" {
  command = plan

  variables {
    egress_firewall = {
      enabled  = true
      policies = { cluster = { network_allow = { quic = { destination_ipv4_cidrs = ["8.8.8.0/24"], protocol = "udp", destination_ports = [443], reason = "QUIC" } } } }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "rejects_private_destinations" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = { cluster = { network_allow = {
        private = { destination_ipv4_cidrs = ["10.20.0.0/16"], protocol = "tcp", destination_ports = [5432], reason = "Private database" }
      } } }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "rejects_public_suffix_wildcards" {
  command = plan

  variables {
    egress_firewall = {
      enabled  = true
      policies = { cluster = { domain_allow = { google = { domains = ["*.googleapis.com"], protocol = "https" } } } }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

# *.run.app is itself a public suffix rule: every Cloud Run service name under it is a suffix.
run "rejects_public_suffix_wildcard_rules" {
  command = plan

  variables {
    egress_firewall = {
      enabled  = true
      policies = { cluster = { domain_allow = { cloud_run = { domains = ["*.run.app"], protocol = "https" } } } }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "rejects_https_on_port_80" {
  command = plan

  variables {
    egress_firewall = {
      enabled  = true
      policies = { cluster = { domain_allow = { odd = { domains = ["api.vendor.example"], protocol = "https", destination_ports = [80] } } } }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "rejects_attachment_to_retired_group" {
  command = plan

  variables {
    additional_subnet_groups = [
      { name = "api_clients", ipv4_prefix_length = 24, retired = true },
      { name = "batch", ipv4_prefix_length = 26 },
    ]
  }

  expect_failures = [var.egress_attachments]
}

run "rejects_overlapping_layout" {
  command = plan

  variables {
    additional_subnet_groups_cidr = "10.0.64.0/18"
  }

  expect_failures = [terraform_data.network_layout_contract]
}

run "rejects_groups_that_do_not_fit" {
  command = plan

  variables {
    additional_subnet_groups = [{ name = "api_clients", ipv4_prefix_length = 18 }]
  }

  expect_failures = [terraform_data.additional_subnet_contract]
}

run "enabled_native_policy_scopes_nat_and_reports_readiness" {
  command = apply
  assert {
    condition     = length(output.outbound_ips) == 1 && toset(output.outbound_ips) == toset(output.egress_firewall.web_egress_ips) && toset(output.egress_firewall.web_egress_ips) == toset(output.egress_firewall.nat_public_ips)
    error_message = "Inspected web and exact exceptions must reuse the root address, without proxy-owned NAT."
  }
  assert {
    condition     = length(google_compute_router_nat.nat.subnetwork) == 2 && google_compute_router_nat.nat.log_config[0].filter == "ALL" && output.egress_firewall.readiness.ready && !output.egress_firewall.capabilities.https_only_enforced
    error_message = "Cluster and attached external groups need NAT and truthful API readiness, not protocol parity."
  }
  assert {
    condition     = module.gcp-network.network.network.network_firewall_policy_enforcement_order == "BEFORE_CLASSIC_FIREWALL" && !module.gcp-network.subnets["us-central1/gke-subnet-eg"].private_ip_google_access
    error_message = "Policy must precede classic rules and Google APIs must not use a private bypass."
  }
}

run "accepts_psl_exception_registrable_wildcard" {
  command = plan
  variables {
    egress_firewall = {
      enabled            = true
      cluster_policy_key = "customer"
      policies           = { customer = { domain_allow = { exception = { protocol = "https", domains = ["*.city.kawasaki.jp"] } } } }
    }
    egress_attachments = {}
  }
}

run "rejects_assigned_psa_collision" {
  command   = apply
  state_key = "psa-collision"
  variables {
    additional_subnet_groups_cidr = "10.21.0.0/20"
  }
  expect_failures = [terraform_data.network_layout_contract]
}

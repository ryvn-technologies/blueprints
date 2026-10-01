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

  mock_data "azurerm_virtual_network" {
    defaults = {
      id                  = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet"
      name                = "vnet"
      resource_group_name = "rg"
      location            = "eastus2"
      address_space       = ["10.0.0.0/16"]
      guid                = "00000000-0000-0000-0000-000000000005"
    }
  }
}

mock_provider "azapi" {}
mock_provider "local" {}
mock_provider "null" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  environment_name     = "egress-fw-test"
  location             = "eastus2"
  public_root_domain   = "test.example.com"
  internal_root_domain = "test.internal"
  zones                = ["1"]

  egress_firewall = {
    enabled            = true
    default_action     = "deny"
    cluster_policy_key = "cluster"
    policies = {
      cluster = {
        domain_allow = {
          https = { domains = ["api.vendor.example", "*.customer.example"], protocol = "https" }
          http  = { domains = ["mirror.customer.example"], protocol = "http" }
        }
        network_allow = {
          smtp_relay = {
            destination_ipv4_cidrs = ["8.8.8.0/24"]
            protocol               = "tcp"
            destination_ports      = [587]
            reason                 = "Outbound SMTP relay pinned by IP"
          }
        }
      }
      workers = {
        domain_allow = {
          https = { domains = ["api.vendor.example", "*.customer.example"], protocol = "https" }
        }
      }
    }
  }

  additional_subnet_groups = [{ name = "api_clients", ipv4_prefix_length = 24 }]
  egress_attachments = {
    api_clients = { policy_key = "workers", subnet_group_key = "api_clients" }
  }
}

# ---------------------------------------------------------------------------
# Disabled / omitted mode
# ---------------------------------------------------------------------------

run "disabled_by_default_preserves_legacy_topology" {
  command = plan

  variables {
    egress_firewall          = {}
    additional_subnet_groups = []
    egress_attachments       = {}
  }

  assert {
    condition     = length(module.egress_firewall) == 0 && length(azurerm_subnet.firewall) == 0
    error_message = "Omitted egress_firewall must not create firewall resources."
  }

  assert {
    condition     = module.aks.network_profile[0].outbound_type == "loadBalancer"
    error_message = "Omitted egress_firewall must preserve AKS loadBalancer outbound."
  }

  assert {
    condition     = output.egress_firewall.enabled == false && output.egress_firewall.attachments == {}
    error_message = "Disabled mode must publish enabled=false and an empty attachment map."
  }

  assert {
    condition     = azurerm_subnet.main["private-1"].service_endpoints != null && length(azurerm_subnet.main["private-1"].service_endpoints) == 4
    error_message = "Disabled mode must keep existing node-pool service endpoints."
  }

  assert {
    condition     = azurerm_subnet.main["private-1"].default_outbound_access_enabled == true
    error_message = "Disabled mode must keep Azure default outbound access on node-pool subnets."
  }
}

run "disabled_mode_rejects_attachments" {
  command = plan

  variables {
    egress_firewall = {}
  }

  expect_failures = [var.egress_attachments]
}

# ---------------------------------------------------------------------------
# Enabled: topology
# ---------------------------------------------------------------------------

run "enabled_routes_every_node_pool_subnet_through_firewall" {
  command = plan

  assert {
    condition     = module.aks.network_profile[0].outbound_type == "userDefinedRouting"
    error_message = "Managed firewall mode must set AKS outbound type to userDefinedRouting."
  }

  assert {
    condition     = module.aks.network_profile[0].load_balancer_profile == null || length(module.aks.network_profile[0].load_balancer_profile) == 0
    error_message = "Managed firewall mode must not keep AKS-managed outbound load balancer IPs."
  }

  assert {
    condition     = toset(keys(azurerm_subnet_route_table_association.egress_node_pool)) == toset(["private-1", "private-2", "private-3"])
    error_message = "Every node-pool subnet must be associated with the firewall route table."
  }

  assert {
    condition     = toset(keys(azurerm_subnet_route_table_association.additional_group)) == toset(["api_clients"])
    error_message = "Every external attachment subnet must be associated with the firewall route table."
  }

  assert {
    condition     = length(azurerm_subnet.main["private-1"].service_endpoints) == 0
    error_message = "Managed firewall mode must remove node-pool service endpoints that would bypass the UDR."
  }

  assert {
    condition = alltrue([
      for name in ["private-1", "private-2", "private-3"] : azurerm_subnet.main[name].default_outbound_access_enabled == false
    ]) && azurerm_subnet.main["privatelink-subnet"].default_outbound_access_enabled == true
    error_message = "Managed firewall mode must disable implicit default outbound access on every node-pool subnet (and only those) so a lost route fails closed."
  }

  assert {
    condition     = output.egress_firewall.implementation == "azure-firewall" && output.egress_firewall.default_action == "deny"
    error_message = "Output must publish implementation and deny default."
  }

  assert {
    condition     = output.egress_firewall.compiled_policy.firewall_policy_sku == "Standard" && output.egress_firewall.compiled_policy.firewall_policy_name_prefix == "afwp-egress-fw-test-egress-standard-"
    error_message = "Standard policy name must carry the tier before its generation suffix."
  }

  assert {
    condition     = length(data.azapi_resource_list.aks_node_rg_public_ips) == 0
    error_message = "Managed firewall mode must not read AKS-managed outbound IPs."
  }
}

run "firewall_subnet_uses_fixed_slot_four_without_shifting_existing_ranges" {
  command = plan

  assert {
    condition     = azurerm_subnet.firewall[0].name == "AzureFirewallSubnet"
    error_message = "Firewall subnet must be named AzureFirewallSubnet."
  }

  # Default /16 overlay layout: infra half 10.0.128.0/17, /24 slots; slot 4 = 10.0.132.0/24.
  assert {
    condition     = one(azurerm_subnet.firewall[0].address_prefixes) == "10.0.132.0/24"
    error_message = "Firewall subnet must occupy fixed allocator slot 4."
  }

  assert {
    condition = (
      one(azurerm_subnet.main["private-1"].address_prefixes) == "10.0.0.0/19" &&
      one(azurerm_subnet.main["appgw-subnet"].address_prefixes) == "10.0.128.0/24" &&
      one(azurerm_subnet.main["privatelink-subnet"].address_prefixes) == "10.0.129.0/24" &&
      local.service_subnet_pool_cidr == "10.0.130.0/24" &&
      local.postgres_subnet_cidr == "10.0.131.0/24"
    )
    error_message = "Existing allocator indices must not shift when the firewall subnet is added."
  }
}

run "firewall_subnet_is_at_least_slash_26_on_smallest_supported_vnet" {
  command = plan

  variables {
    vnet_cidr                = "10.0.0.0/21"
    additional_subnet_groups = [{ name = "api_clients", ipv4_prefix_length = 26 }]
    egress_attachments       = { api_clients = { policy_key = "workers", subnet_group_key = "api_clients" } }
  }

  assert {
    condition     = one(azurerm_subnet.firewall[0].address_prefixes) == "10.0.5.0/26"
    error_message = "A /21 VNet must yield a /26 firewall subnet at slot 4."
  }
}

run "compact_vnet_is_rejected_in_managed_mode" {
  command = plan

  variables {
    vnet_cidr                = "10.0.0.0/22"
    additional_subnet_groups = []
    egress_attachments       = {}
  }

  expect_failures = [var.egress_firewall]
}

run "existing_vnet_is_rejected_in_managed_mode" {
  command = plan

  variables {
    existing_vnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet"
    egress_attachments       = {}
    additional_subnet_groups = []
  }

  expect_failures = [var.egress_firewall]
}

run "existing_route_table_is_rejected_in_managed_mode" {
  command = plan

  variables {
    existing_route_table_id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/routeTables/rt"
    egress_attachments      = {}
  }

  expect_failures = [var.egress_firewall]
}

run "legacy_existing_route_table_still_works_when_disabled" {
  command = plan

  variables {
    egress_firewall         = {}
    egress_attachments      = {}
    existing_route_table_id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg/providers/Microsoft.Network/routeTables/rt"
  }

  assert {
    condition     = module.aks.network_profile[0].outbound_type == "userDefinedRouting" && length(azurerm_subnet_route_table_association.node_pool) == 3
    error_message = "Legacy caller-managed route table behavior must be preserved."
  }
}

# ---------------------------------------------------------------------------
# Enabled: policy input validation
# ---------------------------------------------------------------------------

run "default_action_allow_is_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled        = true
      default_action = "allow"
      policies       = { cluster = {} }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "missing_cluster_policy_key_is_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled            = true
      cluster_policy_key = "nope"
      policies           = { cluster = {} }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "unsupported_tier_is_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled  = true
      tier     = "Basic"
      policies = { cluster = {} }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "invalid_domains_are_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {
          domain_allow = {
            https = { protocol = "https", domains = [
              "*",                       # bare wildcard
              "*.com",                   # public-suffix-only wildcard
              "*.co.uk",                 # multi-label public suffix
              ".example.com",            # leading dot
              "*customer.example",       # partial-label wildcard
              "api.*.example.com",       # internal wildcard
              "203.0.113.10",            # IP literal
              "https://api.example.com", # URL
              "api.example.com/v1",      # path
              "api.example.com:8443",    # port
              "Api.Example.com",         # not lowercase
              "api.example.com.",        # trailing dot
              "-bad.example.com",        # invalid label
              "example",                 # single label
            ] }
          }
        }
      }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "each_invalid_domain_is_rejected_individually" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = { domain_allow = { http = { domains = ["*customer.example"], protocol = "http" } } }
      }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "invalid_network_allows_are_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {
          network_allow = {
            everything = {
              destination_ipv4_cidrs = ["0.0.0.0/0"]
              protocol               = "tcp"
              destination_ports      = [443]
              reason                 = "too broad"
            }
          }
        }
      }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "ipv6_network_allow_is_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {
          network_allow = {
            v6 = {
              destination_ipv4_cidrs = ["2001:db8::/32"]
              protocol               = "tcp"
              destination_ports      = [443]
              reason                 = "ipv6"
            }
          }
        }
      }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "non_normalized_cidr_is_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {
          network_allow = {
            sloppy = {
              destination_ipv4_cidrs = ["8.8.8.7/24"]
              protocol               = "tcp"
              destination_ports      = [443]
              reason                 = "host bits set"
            }
          }
        }
      }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "multicast_and_reserved_cidrs_are_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {
          network_allow = {
            mcast = {
              destination_ipv4_cidrs = ["224.0.0.0/24"]
              protocol               = "udp"
              destination_ports      = [5353]
              reason                 = "multicast"
            }
          }
        }
      }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "private_range_network_allow_is_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {
          network_allow = {
            rfc1918 = {
              destination_ipv4_cidrs = ["10.0.0.0/8"]
              protocol               = "tcp"
              destination_ports      = [443]
              reason                 = "private"
            }
          }
        }
      }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "udp_443_pinhole_is_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {
          network_allow = {
            quic = {
              destination_ipv4_cidrs = ["8.8.8.0/24"]
              protocol               = "udp"
              destination_ports      = [443]
              reason                 = "quic"
            }
          }
        }
      }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "network_allow_requires_ports_protocol_and_reason" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {
          network_allow = {
            noports = {
              destination_ipv4_cidrs = ["8.8.8.0/24"]
              protocol               = "icmp"
              destination_ports      = []
              reason                 = ""
            }
          }
        }
      }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

run "out_of_range_port_is_rejected" {
  command = plan

  variables {
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {
          network_allow = {
            bigport = {
              destination_ipv4_cidrs = ["8.8.8.0/24"]
              protocol               = "tcp"
              destination_ports      = [0, 70000]
              reason                 = "bad ports"
            }
          }
        }
      }
    }
    egress_attachments = {}
  }

  expect_failures = [var.egress_firewall]
}

# ---------------------------------------------------------------------------
# Enabled: attachment validation
# ---------------------------------------------------------------------------

run "attachment_with_unknown_policy_is_rejected" {
  command = plan

  variables {
    egress_attachments = { api_clients = { policy_key = "missing", subnet_group_key = "api_clients" } }
  }

  expect_failures = [var.egress_attachments]
}

run "reserved_cluster_attachment_name_is_rejected" {
  command = plan

  variables {
    egress_attachments = { cluster = { policy_key = "workers", subnet_group_key = "api_clients" } }
  }

  expect_failures = [var.egress_attachments]
}

run "attachment_with_unknown_group_is_rejected" {
  command = plan

  variables {
    egress_attachments = { api_clients = { policy_key = "workers", subnet_group_key = "unknown" } }
  }

  expect_failures = [var.egress_attachments]
}

run "overlapping_attachments_are_rejected" {
  command = plan

  variables {
    egress_attachments = {
      a = { policy_key = "workers", subnet_group_key = "api_clients" }
      b = { policy_key = "cluster", subnet_group_key = "api_clients" }
    }
  }

  expect_failures = [var.egress_attachments]
}

run "retired_subnet_group_cannot_be_attached" {
  command = plan

  variables {
    additional_subnet_groups = [{ name = "api_clients", ipv4_prefix_length = 24, retired = true }]
  }

  expect_failures = [var.egress_attachments]
}

# ---------------------------------------------------------------------------
# Enabled: compiled policy
# ---------------------------------------------------------------------------

run "compiled_policy_orders_network_allows_web_allows_then_explicit_web_deny" {
  command = plan

  assert {
    condition     = output.egress_firewall.compiled_policy.firewall_policy_sku == "Standard" && output.egress_firewall.compiled_policy.dns_proxy_enabled
    error_message = "Standard tier policy must be compiled with DNS proxy enabled for post-creation FQDN network rules."
  }

  # No network deny-all and no permit-rest anywhere.
  assert {
    condition = alltrue([
      for collection in output.egress_firewall.compiled_policy.network_rule_collections : collection.action == "Allow"
    ])
    error_message = "Network collections must only contain narrow allows; no network deny-all before application evaluation."
  }

  assert {
    condition = alltrue(flatten([
      for collection in output.egress_firewall.compiled_policy.network_rule_collections : [
        for rule in collection.rules : !contains(rule.destination_addresses, "*") && !contains(rule.destination_addresses, "0.0.0.0/0") && !contains(rule.destination_ports, "*")
      ]
    ]))
    error_message = "Network allows must be narrow: no wildcard destinations or any-port forms."
  }

  # Final application deny covers HTTP/80 and HTTPS/443 with the highest priority number.
  assert {
    condition = (
      length([for c in output.egress_firewall.compiled_policy.application_rule_collections : c if c.action == "Deny"]) == 1 &&
      one([for c in output.egress_firewall.compiled_policy.application_rule_collections : c if c.action == "Deny"]).priority == max([for c in output.egress_firewall.compiled_policy.application_rule_collections : c.priority]...) &&
      one([for c in output.egress_firewall.compiled_policy.application_rule_collections : c if c.action == "Deny"]).rules[0].destination_fqdns[0] == "*" &&
      one([for c in output.egress_firewall.compiled_policy.application_rule_collections : c if c.action == "Deny"]).rules[0].source_addresses[0] == "*" &&
      toset([for p in one([for c in output.egress_firewall.compiled_policy.application_rule_collections : c if c.action == "Deny"]).rules[0].protocols : "${p.type}:${p.port}"]) == toset(["Http:80", "Https:443"])
    )
    error_message = "Exactly one explicit final application DENY * on Http:80 and Https:443 must follow all allow collections."
  }

  # No allow collection contains a permit-rest or broad cloud wildcard.
  assert {
    condition = alltrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [
        for r in c.rules : !contains(r.destination_fqdns, "*") && length(r.destination_fqdn_tags) == 0 && r.terminate_tls == false
      ] if c.action == "Allow"
    ]))
    error_message = "Allow collections must not use *, provider FQDN tags, or TLS termination."
  }

  assert {
    condition = alltrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [
        for r in c.rules : length(setintersection(toset(r.destination_fqdns), toset(["*.azure.com", "*.windows.net", "*.microsoft.com", "*.core.windows.net"]))) == 0
      ]
    ]))
    error_message = "Baseline must not use broad AzureCloud-wide wildcards."
  }
}

run "customer_https_and_http_allows_are_separate_rules" {
  command = plan

  assert {
    condition = anytrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [
        for r in c.rules : (
          r.name == "cluster-customer-https" &&
          toset(r.destination_fqdns) == toset(["*.customer.example", "api.vendor.example"]) &&
          [for p in r.protocols : "${p.type}:${p.port}"] == ["Https:443"] &&
          toset(r.source_addresses) == toset(["10.0.0.0/19", "10.0.32.0/19", "10.0.64.0/19"])
        )
      ]
    ]))
    error_message = "Cluster HTTPS customer allow must be a single Https:443 rule sourced from every node-pool subnet."
  }

  assert {
    condition = anytrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [
        for r in c.rules : (
          r.name == "cluster-customer-http" &&
          tolist(r.destination_fqdns) == tolist(["mirror.customer.example"]) &&
          [for p in r.protocols : "${p.type}:${p.port}"] == ["Http:80"]
        )
      ]
    ]))
    error_message = "Cluster HTTP customer allow must be a separate Http:80 rule."
  }

  # HTTPS-only names never appear in an Http:80 allow rule.
  assert {
    condition = alltrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [
        for r in c.rules : !(contains([for p in r.protocols : p.type], "Http") && contains(r.destination_fqdns, "api.vendor.example"))
      ] if c.action == "Allow"
    ]))
    error_message = "HTTPS-only allows must not be promoted to HTTP allows."
  }

  assert {
    condition = anytrue(flatten([
      for c in output.egress_firewall.compiled_policy.network_rule_collections : [
        for r in c.rules : (
          r.name == "cluster-customer-smtp_relay" &&
          tolist(r.destination_addresses) == tolist(["8.8.8.0/24"]) &&
          tolist(r.protocols) == tolist(["TCP"]) &&
          tolist(r.destination_ports) == tolist(["587"])
        )
      ]
    ]))
    error_message = "Customer network pinhole must compile to a narrow network rule."
  }
}

run "external_class_gets_own_sources_and_no_cluster_baseline" {
  command = plan

  assert {
    condition = anytrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [
        for r in c.rules : r.name == "api_clients-customer-https" && tolist(r.source_addresses) == tolist(["10.0.96.0/24"])
      ]
    ]))
    error_message = "External attachment class must compile its own source-scoped customer rule."
  }

  assert {
    condition = alltrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [
        for r in c.rules : !(contains(r.source_addresses, "10.0.96.0/24") && anytrue([for f in r.destination_fqdns : can(regex("azmk8s\\.io$|mcr\\.microsoft\\.com$", f))]))
      ]
    ]))
    error_message = "External classes must not inherit cluster-only AKS baseline destinations."
  }

  assert {
    condition = alltrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [
        for r in c.rules : !(contains(r.source_addresses, "10.0.96.0/24") && contains(r.source_addresses, "10.0.0.0/19"))
      ]
    ]))
    error_message = "Cluster and external classes must never share a compiled source set."
  }

  assert {
    condition = alltrue([
      for rule in output.egress_firewall.effective_rules : rule.class != "api_clients" || rule.source != "platform-cluster"
    ])
    error_message = "Effective rules for external classes must not carry cluster baseline entries."
  }
}

run "cluster_baseline_covers_aks_bootstrap_and_flags_bypasses" {
  command = plan

  assert {
    condition = anytrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [
        for r in c.rules : (
          r.name == "cluster-platform-aks-https" &&
          contains(r.destination_fqdns, "*.hcp.eastus2.azmk8s.io") &&
          contains(r.destination_fqdns, "mcr.microsoft.com") &&
          contains(r.destination_fqdns, "*.data.mcr.microsoft.com") &&
          contains(r.destination_fqdns, "management.azure.com") &&
          contains(r.destination_fqdns, "login.microsoftonline.com") &&
          contains(r.destination_fqdns, "packages.aks.azure.com")
        )
      ]
    ]))
    error_message = "Cluster baseline must include the region-specific AKS control-plane and registry FQDNs."
  }

  assert {
    condition = alltrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [
        for r in c.rules : !contains(r.destination_fqdns, "*.hcp.eastus.azmk8s.io")
      ]
    ]))
    error_message = "Baseline must be derived from the configured region, not a hardcoded one."
  }

  assert {
    condition     = length([for r in output.egress_firewall.effective_rules : r if r.bypasses_hostname_check]) >= 1
    error_message = "Network pinholes must be flagged as hostname bypasses in effective_rules."
  }

  assert {
    condition = alltrue([
      for r in output.egress_firewall.effective_rules : length(r.reason) > 0 && length(r.id) > 0
    ])
    error_message = "Every effective rule must carry a stable id and a reason."
  }

  assert {
    condition     = length(output.egress_firewall.platform_baseline_version) > 0 && length(output.egress_firewall.exclusions) > 0
    error_message = "Output must publish a baseline version and named exclusions."
  }

  assert {
    condition     = output.egress_firewall.log_refs.retention_days == 30 && toset(output.egress_firewall.log_refs.categories) == toset(["AZFWApplicationRule", "AZFWNetworkRule", "AZFWDnsQuery"])
    error_message = "Diagnostics must collect application and network verdicts with 30-day retention."
  }
}

run "api_server_exception_is_post_creation_and_not_in_pre_policy" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for c in output.egress_firewall.compiled_policy.network_rule_collections : [
        for r in c.rules : !can(regex("api-server", r.name))
      ]
    ]))
    error_message = "The API-server-by-IP exception must not be part of the pre-creation policy."
  }

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.api_server) == 1
    error_message = "A post-creation API-server exception collection group must exist."
  }
}

run "attachment_descriptor_is_versioned_and_flat" {
  command = plan

  assert {
    condition = (
      output.egress_firewall.attachments["api_clients"].schema_version == 1 &&
      output.egress_firewall.attachments["api_clients"].provider == "azure" &&
      output.egress_firewall.attachments["api_clients"].subnet_group_key == "api_clients" &&
      output.egress_firewall.attachments["api_clients"].policy_key == "workers" &&
      output.egress_firewall.attachments["api_clients"].ipv4_cidr == "10.0.96.0/24" &&
      output.egress_firewall.attachments["api_clients"].location == "eastus2"
    )
    error_message = "External attachment descriptor must be a flat schema_version=1 Azure object."
  }

  assert {
    condition     = !contains(keys(output.egress_firewall.attachments), "cluster")
    error_message = "The reserved cluster attachment is not an external compute descriptor."
  }

  assert {
    condition     = terraform_data.additional_subnet_geometry["api_clients"].input.ipv4_cidr == "10.0.96.0/24" && length(azurerm_subnet.additional_group["api_clients"].service_endpoints) == 0 && azurerm_subnet.additional_group["api_clients"].default_outbound_access_enabled == false
    error_message = "External class subnet must be pre-created with the declared CIDR and no bypassing service endpoints."
  }
}

# ---------------------------------------------------------------------------
# Tier handling
# ---------------------------------------------------------------------------

run "premium_tier_does_not_enable_tls_inspection" {
  command = plan

  variables {
    egress_attachments = {}
    egress_firewall = {
      enabled = true
      tier    = "Premium"
      policies = { cluster = { domain_allow = { https = { domains = ["api.vendor.example"], protocol = "https" }
      } } }
    }
  }

  assert {
    condition     = output.egress_firewall.compiled_policy.firewall_policy_sku == "Premium" && output.egress_firewall.compiled_policy.tls_inspection_enabled == false
    error_message = "Premium tier must not silently enable TLS inspection."
  }

  assert {
    condition     = output.egress_firewall.compiled_policy.firewall_policy_name_prefix == "afwp-egress-fw-test-egress-premium-"
    error_message = "Premium policy must carry a tier- and generation-suffixed name so it can be created next to the attached Standard policy before the firewall switches."
  }

  assert {
    condition = alltrue(flatten([
      for c in output.egress_firewall.compiled_policy.application_rule_collections : [for r in c.rules : r.terminate_tls == false]
    ]))
    error_message = "No application rule may terminate TLS."
  }
}

run "flat_cni_uses_node_pool_subnets_as_cluster_sources" {
  command = plan

  variables {
    network_plugin_mode = "flat"
    egress_attachments  = { api_clients = { policy_key = "workers", subnet_group_key = "api_clients" } }
  }

  assert {
    condition     = toset(output.egress_firewall.configured_scope.cluster_sources) == toset(["10.0.0.0/21", "10.0.8.0/21", "10.0.16.0/21"])
    error_message = "Flat CNI cluster sources must be the node-pool subnets (pods share node subnet IPs)."
  }

  assert {
    condition     = one(azurerm_subnet.firewall[0].address_prefixes) == "10.0.132.0/24"
    error_message = "Flat mode firewall slot must also be allocator slot 4."
  }
}

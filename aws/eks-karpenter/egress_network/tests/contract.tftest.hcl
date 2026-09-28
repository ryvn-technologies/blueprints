mock_provider "aws" {}

variables {
  name                  = "egress-contract-test"
  vpc_id                = "vpc-test"
  vpc_cidr              = "10.42.0.0/16"
  igw_id                = "igw-test"
  azs                   = ["us-east-1a"]
  cluster_subnets_by_az = { us-east-1a = { subnet_id = "subnet-cluster", ipv4_cidr = "10.42.0.0/20", route_table_id = "rtb-cluster" } }
  firewall_subnet_cidrs = { us-east-1a = "10.42.240.0/28" }
  nat_subnet_cidrs      = { us-east-1a = "10.42.56.0/24" }
  attachments = {
    clients = { policy_key = "clients", subnets_by_az = { us-east-1a = { ipv4_cidr = "10.42.64.0/24" } } }
  }
  policies = {
    cluster = { network_allow = {} }
    clients = {
      domain_allow  = { partner = { domains = ["api.example.com", "*.example.org"], protocol = "https" }, plain = { domains = ["plain.example.net"], protocol = "http" } }
      network_allow = { ssh = { destination_ipv4_cidrs = ["8.8.8.8/32"], protocol = "tcp", destination_ports = [22], reason = "partner SFTP" } }
    }
  }
  cluster_policy_key = "cluster"
}

run "distinct_web_ports_and_sources" {
  command = plan
  assert {
    condition     = length(regexall("pass tls.*10[.]42[.]64[.]0/24.*443.*api[.]example[.]com", output.suricata_rules)) == 1 && length(regexall("pass tls.*[.]example[.]org", output.suricata_rules)) == 1
    error_message = "TLS rules must use the clients source and exact/suffix names."
  }
  assert {
    condition     = length(regexall("pass http.*80.*plain[.]example[.]net", output.suricata_rules)) == 1 && length(regexall("pass http.*443", output.suricata_rules)) == 0
    error_message = "HTTP names must not authorize TLS/443."
  }
  assert {
    condition     = length(regexall("pass tls.*10[.]42[.]0[.]0/20", output.suricata_rules)) == 0 && length(regexall("dotprefix", output.suricata_rules)) == 0
    error_message = "Worker domains cannot become cluster or apex permissions."
  }
  assert {
    condition     = output.attachments.clients.schema_version == 1 && output.attachments.clients.provider == "aws"
    error_message = "Compute attachment requires a versioned native descriptor."
  }
}

run "shared_customer_policy_keeps_cluster_baseline_source_scoped" {
  command = plan
  variables {
    cluster_policy_key     = "shared"
    platform_https_domains = ["auth.docker.io"]
    attachments = {
      clients = { policy_key = "shared", subnets_by_az = { us-east-1a = { ipv4_cidr = "10.42.64.0/24" } } }
    }
    policies = {
      shared = { domain_allow = { partner = { domains = ["api.example.com"], protocol = "https" } } }
    }
  }
  assert {
    condition     = length(regexall("pass tls .*10[.]42[.]0[.]0/20.*auth[.]docker[.]io", output.suricata_rules)) == 1 && length(regexall("pass tls .*10[.]42[.]64[.]0/24.*auth[.]docker[.]io", output.suricata_rules)) == 0
    error_message = "Only cluster sources may use the platform baseline with a shared customer policy."
  }
  assert {
    condition     = length(regexall("pass tls .*10[.]42[.]0[.]0/20.*api[.]example[.]com", output.suricata_rules)) == 1 && length(regexall("pass tls .*10[.]42[.]64[.]0/24.*api[.]example[.]com", output.suricata_rules)) == 1
    error_message = "The shared customer policy must still apply to both source classes."
  }
}

run "reject_udp_quic_pinhole" {
  command = plan
  variables {
    policies = {
      cluster = { network_allow = { quic = { destination_ipv4_cidrs = ["8.8.8.8/32"], protocol = "udp", destination_ports = [443], reason = "invalid" } } }
      clients = { network_allow = {} }
    }
  }
  expect_failures = [var.policies]
}

run "reject_broad_network_pinhole" {
  command = plan
  variables {
    policies = {
      cluster = { network_allow = { broad = { destination_ipv4_cidrs = ["0.0.0.0/0"], protocol = "tcp", destination_ports = [443], reason = "invalid" } } }
      clients = { network_allow = {} }
    }
  }
  expect_failures = [var.policies]
}

run "reject_public_suffix_wildcard" {
  command = plan
  variables {
    policies = {
      cluster = { domain_allow = { rule = { domains = ["*.co.uk"], protocol = "https" } }, network_allow = {} }
      clients = { network_allow = {} }
    }
  }
  expect_failures = [terraform_data.contract]
}

run "reject_invalid_hostname" {
  command = plan
  variables {
    policies = {
      cluster = { domain_allow = { rule = { domains = ["api.example.com:443"], protocol = "https" } }, network_allow = {} }
      clients = { network_allow = {} }
    }
  }
  expect_failures = [var.policies]
}

run "reject_unknown_policy" {
  command = plan
  variables {
    attachments = { clients = { policy_key = "missing", subnets_by_az = { us-east-1a = { ipv4_cidr = "10.42.64.0/24" } } } }
  }
  expect_failures = [terraform_data.contract]
}

run "reject_overlapping_attachment" {
  command = plan
  variables {
    attachments = { clients = { policy_key = "clients", subnets_by_az = { us-east-1a = { ipv4_cidr = "10.42.0.0/24" } } } }
  }
  expect_failures = [terraform_data.contract]
}

run "reject_uncovered_zone" {
  command = plan
  variables {
    attachments = { clients = { policy_key = "clients", subnets_by_az = { us-east-1b = { ipv4_cidr = "10.42.64.0/24" } } } }
  }
  expect_failures = [terraform_data.contract]
}

run "reject_missing_reason" {
  command = plan
  variables {
    policies = {
      cluster = { network_allow = { ssh = { destination_ipv4_cidrs = ["8.8.8.8/32"], protocol = "tcp", destination_ports = [22], reason = " " } } }
      clients = { network_allow = {} }
    }
  }
  expect_failures = [var.policies]
}

run "reject_private_destination_overlap" {
  command = plan
  variables {
    policies = {
      cluster = { network_allow = { broad = { destination_ipv4_cidrs = ["8.0.0.0/6"], protocol = "tcp", destination_ports = [22], reason = "invalid" } } }
      clients = { network_allow = {} }
    }
  }
  expect_failures = [terraform_data.contract]
}

run "reject_wildcard_public_suffix_rule" {
  command = plan
  variables {
    policies = {
      cluster = { domain_allow = { rule = { domains = ["*.foo.ck"], protocol = "https" } }, network_allow = {} }
      clients = { network_allow = {} }
    }
  }
  expect_failures = [terraform_data.contract]
}

# 公司.cn is a public suffix; its vendored ASCII form must be matched.
run "reject_punycode_public_suffix_wildcard" {
  command = plan
  variables {
    policies = {
      cluster = { domain_allow = { rule = { domains = ["*.xn--55qx5d.cn"], protocol = "https" } }, network_allow = {} }
      clients = { network_allow = {} }
    }
  }
  expect_failures = [terraform_data.contract]
}

run "accept_registrable_punycode_domain" {
  command = plan
  variables {
    policies = {
      cluster = { domain_allow = { rule = { domains = ["xn--80ak6aa92e.xn--55qx5d.cn", "*.xn--bcher-kva.example"], protocol = "https" } }, network_allow = {} }
      clients = { network_allow = {} }
    }
  }
  assert {
    condition     = contains(keys(output.effective_rules), "cluster/domain/rule/https/443/xn--80ak6aa92e.xn--55qx5d.cn") && contains(keys(output.effective_rules), "cluster/domain/rule/https/443/*.xn--bcher-kva.example")
    error_message = "Registrable Punycode names (exact and wildcard below a registrable name) must compile."
  }
}

run "reject_exact_duplicate_source_cidr" {
  command = plan
  variables {
    attachments = { clients = { policy_key = "clients", subnets_by_az = { us-east-1a = { ipv4_cidr = "10.42.0.0/20" } } } }
  }
  expect_failures = [terraform_data.contract]
}

run "effective_rules_mirror_compiler" {
  command = plan
  variables {
    platform_https_domains = ["registry.k8s.io"]
    policies = {
      cluster = { network_allow = {} }
      clients = {
        domain_allow  = { plain = { domains = ["plain.example.net"], protocol = "http" } }
        network_allow = { raw = { destination_ipv4_cidrs = ["8.8.8.8/32", "1.1.1.1/32"], protocol = "tcp", destination_ports = [443, 22], reason = "pinned partner" } }
      }
    }
  }
  assert {
    condition     = toset(keys(output.effective_rules)) == toset(["cluster/platform/https/443/registry.k8s.io", "clients/domain/plain/http/80/plain.example.net", "clients/network/raw"])
    error_message = "effective_rules must carry exactly the compiled pass rules."
  }
  assert {
    condition     = output.effective_rules["cluster/platform/https/443/registry.k8s.io"].origin == "platform" && output.effective_rules["clients/domain/plain/http/80/plain.example.net"].origin == "customer" && tolist(output.effective_rules["clients/domain/plain/http/80/plain.example.net"].destination_ports) == tolist([80]) && !output.effective_rules["clients/domain/plain/http/80/plain.example.net"].bypasses_domain_matching
    error_message = "Origin and web port metadata must be reported."
  }
  assert {
    condition     = output.effective_rules["clients/network/raw"].bypasses_domain_matching && tolist(output.effective_rules["clients/network/raw"].destination_cidrs) == tolist(["1.1.1.1/32", "8.8.8.8/32"]) && tolist(output.effective_rules["clients/network/raw"].destination_ports) == tolist([22, 443]) && output.effective_rules["clients/network/raw"].reason == "pinned partner" && output.effective_rules["clients/network/raw"].sid == parseint(substr(sha1("clients/network/raw"), 0, 8), 16)
    error_message = "A TCP 443 IP exception must be flagged as bypassing SNI matching, with sorted CIDRs/ports and the identity-derived SID."
  }
}

run "application_default_and_protocol_closure" {
  command = plan
  assert {
    condition     = aws_networkfirewall_firewall_policy.egress.firewall_policy[0].stateful_default_actions == toset(["aws:drop_established_app_layer_to_server", "aws:alert_established_app_layer_to_server"]) && aws_networkfirewall_firewall_policy.egress.firewall_policy[0].stateful_engine_options[0].stream_exception_policy == "DROP"
    error_message = "The application default and stream exception must deny, with denied application traffic alerted."
  }
  assert {
    condition     = startswith(output.suricata_rules, "drop ip $HOME_NET any -> !$HOME_NET any (ip_proto:!TCP; ip_proto:!UDP;") && !strcontains(output.suricata_rules, "pass tcp $HOME_NET any -> !$HOME_NET 443")
    error_message = "Other protocols must close before application allows without a broad TCP pass."
  }
}

run "nat_route_tables_are_exposed_for_every_zone" {
  command = plan
  variables {
    azs                   = ["us-east-1a", "us-east-1b"]
    cluster_subnets_by_az = { us-east-1a = { subnet_id = "subnet-a", ipv4_cidr = "10.42.0.0/20", route_table_id = "rtb-a" }, us-east-1b = { subnet_id = "subnet-b", ipv4_cidr = "10.42.16.0/20", route_table_id = "rtb-b" } }
    firewall_subnet_cidrs = { us-east-1a = "10.42.240.0/28", us-east-1b = "10.42.240.16/28" }
    nat_subnet_cidrs      = { us-east-1a = "10.42.56.0/24", us-east-1b = "10.42.57.0/24" }
    attachments = {
      clients = { policy_key = "clients", subnets_by_az = { us-east-1a = { ipv4_cidr = "10.42.64.0/24" }, us-east-1b = { ipv4_cidr = "10.42.65.0/24" } } }
    }
  }
  assert {
    condition     = keys(output.nat_route_table_ids) == ["us-east-1a", "us-east-1b"]
    error_message = "Every AZ NAT table must be exposed as an audit identifier."
  }
}

run "nat_local_route_audit_covers_every_vpc_cidr" {
  command = plan
  variables {
    azs                   = ["us-east-1a", "us-east-1b"]
    vpc_cidrs             = ["10.42.0.0/16", "100.64.0.0/16"]
    cluster_subnets_by_az = { us-east-1a = { subnet_id = "subnet-a", ipv4_cidr = "10.42.0.0/20", route_table_id = "rtb-a" }, us-east-1b = { subnet_id = "subnet-b", ipv4_cidr = "10.42.16.0/20", route_table_id = "rtb-b" } }
    cluster_source_cidrs_by_az = {
      us-east-1a = ["100.64.0.0/18"]
      us-east-1b = ["100.64.64.0/18"]
    }
    firewall_subnet_cidrs  = { us-east-1a = "10.42.240.0/28", us-east-1b = "10.42.240.16/28" }
    nat_subnet_cidrs       = { us-east-1a = "10.42.56.0/24", us-east-1b = "10.42.57.0/24" }
    platform_https_domains = ["auth.docker.io"]
  }
  assert {
    condition     = toset(keys(output.nat_local_routes)) == toset(["us-east-1a/10.42.0.0/16", "us-east-1a/100.64.0.0/16", "us-east-1b/10.42.0.0/16", "us-east-1b/100.64.0.0/16"])
    error_message = "Every AZ NAT table must expose one local-route audit entry per VPC CIDR association, primary and secondary."
  }
  assert {
    condition     = length(regexall("pass tls \\[10[.]42[.]0[.]0/20,100[.]64[.]0[.]0/18,10[.]42[.]16[.]0/20,100[.]64[.]64[.]0/18\\] any -> !\\$HOME_NET 443 [(]flow:to_server; tls[.]sni; content:\"auth[.]docker[.]io\"", output.suricata_rules)) == 1 && contains(output.home_net, "100.64.0.0/18") && contains(output.home_net, "100.64.64.0/18")
    error_message = "Secondary-CIDR pod subnets must be part of HOME_NET and of the cluster source set."
  }
  assert {
    condition     = alltrue([for key, route in output.nat_local_routes : route.availability_zone == split("/", key)[0] && route.destination_cidr_block == trimprefix(key, "${route.availability_zone}/")])
    error_message = "Local route audit keys must be az/cidr."
  }
}

run "cluster_source_outside_every_vpc_cidr_is_rejected" {
  command = plan
  variables {
    vpc_cidrs                  = ["10.42.0.0/16"]
    cluster_source_cidrs_by_az = { us-east-1a = ["100.64.0.0/18"] }
  }
  expect_failures = [terraform_data.contract]
}

run "secondary_cidr_source_is_accepted_when_cidr_is_declared" {
  command = plan
  variables {
    vpc_cidrs                  = ["10.42.0.0/16", "100.64.0.0/16"]
    cluster_source_cidrs_by_az = { us-east-1a = ["100.64.0.0/18"] }
  }
  assert {
    condition     = length(output.nat_local_routes) == 2
    error_message = "One local-route audit entry per VPC CIDR."
  }
}

run "firewall_is_change_protected_by_default" {
  command = plan
  assert {
    condition     = aws_networkfirewall_firewall.egress.delete_protection && aws_networkfirewall_firewall.egress.subnet_change_protection && aws_networkfirewall_firewall.egress.firewall_policy_change_protection
    error_message = "Firewall deletion, subnet-mapping and policy-association changes must be protected unless the operator opens a maintenance window."
  }
}

run "maintenance_window_lifts_firewall_protection" {
  command = plan
  variables {
    change_protection = false
  }
  assert {
    condition     = !aws_networkfirewall_firewall.egress.delete_protection && !aws_networkfirewall_firewall.egress.subnet_change_protection && !aws_networkfirewall_firewall.egress.firewall_policy_change_protection
    error_message = "change_protection = false must lift every protection flag so destroy and AZ changes can proceed."
  }
}

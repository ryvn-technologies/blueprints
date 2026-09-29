mock_provider "aws" {}

variables {
  name                  = "egress-domain-rules-test"
  vpc_id                = "vpc-test"
  vpc_cidr              = "10.42.0.0/16"
  igw_id                = "igw-test"
  azs                   = ["us-east-1a"]
  cluster_subnets_by_az = { us-east-1a = { subnet_id = "subnet-cluster", ipv4_cidr = "10.42.0.0/20", route_table_id = "rtb-cluster" } }
  firewall_subnet_cidrs = { us-east-1a = "10.42.240.0/28" }
  nat_subnet_cidrs      = { us-east-1a = "10.42.56.0/24" }
  subnet_groups = {
    clients = { subnets_by_az = { us-east-1a = { subnet_id = "subnet-clients-a", ipv4_cidr = "10.42.64.0/24", route_table_id = "rtb-clients-a" } } }
  }
  attachments = {
    clients = { policy_key = "clients", subnet_group_key = "clients" }
  }
  cluster_policy_key = "cluster"
  policies = {
    cluster = {}
    clients = {
      domain_allow = {
        vendor_api = { domains = ["api.vendor.com", "*.vendor.com"], protocol = "https", destination_ports = [443] }
        plain      = { domains = ["plain.example.net"], protocol = "http" }
      }
    }
  }
}

run "named_rule_compiles_one_pass_rule_per_domain" {
  command = plan
  assert {
    condition = toset(keys(output.effective_rules)) == toset([
      "clients/domain/vendor_api/https/443/api.vendor.com",
      "clients/domain/vendor_api/https/443/*.vendor.com",
      "clients/domain/plain/http/80/plain.example.net",
    ])
    error_message = "Every domain of a named rule must compile to its own identity carrying class, rule key, protocol, port and name."
  }
  assert {
    condition     = output.effective_rules["clients/domain/vendor_api/https/443/api.vendor.com"].domain_rule_key == "vendor_api" && output.effective_rules["clients/domain/vendor_api/https/443/api.vendor.com"].sid == parseint(substr(sha1("clients/domain/vendor_api/https/443/api.vendor.com"), 0, 8), 16)
    error_message = "Effective metadata must expose the rule key and the identity-derived SID."
  }
  assert {
    condition     = length(regexall("pass tls \\[10[.]42[.]64[.]0/24\\] any -> !\\$HOME_NET 443 [(]flow:to_server; tls[.]sni; content:\"api[.]vendor[.]com\"; startswith; endswith; nocase;", output.suricata_rules)) == 1 && length(regexall("pass tls .*content:\"[.]vendor[.]com\"; endswith; nocase;", output.suricata_rules)) == 1
    error_message = "TLS rules must anchor exact names at both ends and suffixes at the end only."
  }
}

run "omitted_ports_default_by_protocol" {
  command = plan
  assert {
    condition     = tolist(output.effective_rules["clients/domain/plain/http/80/plain.example.net"].destination_ports) == tolist([80]) && length(regexall("pass http \\[10[.]42[.]64[.]0/24\\] any -> !\\$HOME_NET 80 [(]flow:to_server; http[.]host; content:\"plain[.]example[.]net\"; startswith; endswith;", output.suricata_rules)) == 1
    error_message = "An http rule without destination_ports must compile to Host matching on port 80 only."
  }
  assert {
    condition     = length(regexall("pass http .*443", output.suricata_rules)) == 0 && length(regexall("pass tls .*plain[.]example[.]net", output.suricata_rules)) == 0
    error_message = "http rules must never authorize TLS/443."
  }
}

run "reject_empty_domains" {
  command = plan
  variables {
    policies = {
      cluster = {}
      clients = { domain_allow = { empty = { domains = [], protocol = "https" } } }
    }
  }
  expect_failures = [var.policies]
}

run "reject_explicit_empty_ports" {
  command = plan
  variables {
    policies = {
      cluster = {}
      clients = { domain_allow = { none = { domains = ["api.vendor.com"], protocol = "https", destination_ports = [] } } }
    }
  }
  expect_failures = [var.policies]
}

run "reject_unknown_protocol" {
  command = plan
  variables {
    policies = {
      cluster = {}
      clients = { domain_allow = { grpc = { domains = ["api.vendor.com"], protocol = "grpc" } } }
    }
  }
  expect_failures = [var.policies]
}

run "reject_https_on_nonstandard_port" {
  command = plan
  variables {
    policies = {
      cluster = {}
      clients = { domain_allow = { alt = { domains = ["api.vendor.com"], protocol = "https", destination_ports = [8443] } } }
    }
  }
  expect_failures = [var.policies]
}

run "reject_http_on_443" {
  command = plan
  variables {
    policies = {
      cluster = {}
      clients = { domain_allow = { swapped = { domains = ["api.vendor.com"], protocol = "http", destination_ports = [443] } } }
    }
  }
  expect_failures = [var.policies]
}

run "reject_domain_with_port_suffix" {
  command = plan
  variables {
    policies = {
      cluster = {}
      clients = { domain_allow = { bad = { domains = ["api.vendor.com:8443"], protocol = "https" } } }
    }
  }
  expect_failures = [var.policies]
}

# Two rule keys naming the same host stay distinct rules: renaming or dropping
# one never changes the other's SID.
run "same_domain_under_two_keys_keeps_distinct_identities" {
  command = plan
  variables {
    policies = {
      cluster = {}
      clients = {
        domain_allow = {
          vendor_api = { domains = ["api.vendor.com"], protocol = "https" }
          billing    = { domains = ["api.vendor.com"], protocol = "https" }
        }
      }
    }
  }
  assert {
    condition     = contains(keys(output.effective_rules), "clients/domain/vendor_api/https/443/api.vendor.com") && contains(keys(output.effective_rules), "clients/domain/billing/https/443/api.vendor.com") && output.effective_rules["clients/domain/vendor_api/https/443/api.vendor.com"].sid != output.effective_rules["clients/domain/billing/https/443/api.vendor.com"].sid
    error_message = "Rule identities must include the rule key so equal domains under different keys do not collide."
  }
}

# host3659/host21860 share a 7-hex SHA-1 prefix under this identity scheme.
run "sid_prefix_neighbours_compile_distinctly" {
  command = plan
  variables {
    policies = {
      cluster = { domain_allow = { vendor = { domains = ["host3659.example.com", "host21860.example.com"], protocol = "https" } } }
      clients = {}
    }
  }
  assert {
    condition     = output.effective_rules["cluster/domain/vendor/https/443/host3659.example.com"].sid == 85449527 && output.effective_rules["cluster/domain/vendor/https/443/host21860.example.com"].sid == 85449520 && length(regexall("sid:85449527;", output.suricata_rules)) == 1 && length(regexall("sid:85449520;", output.suricata_rules)) == 1
    error_message = "SIDs must be the stable 32-bit SHA-1 prefix of the rule identity and render distinctly."
  }
}

# host57194/host115782 collide on the full 32-bit SID under this identity scheme.
run "reject_sid_collision" {
  command = plan
  variables {
    policies = {
      cluster = { domain_allow = { vendor = { domains = ["host57194.example.com", "host115782.example.com"], protocol = "https" } } }
      clients = {}
    }
  }
  expect_failures = [terraform_data.contract]
}

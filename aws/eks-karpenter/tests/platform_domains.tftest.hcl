mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:role/test"
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:role/test"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_subnets" {
    defaults = {
      ids = []
    }
  }
}

mock_provider "random" {}
mock_provider "tls" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "cloudinit" {}

variables {
  environment_name     = "test"
  account_id           = "123456789012"
  internal_root_domain = "internal.example.com"
  public_root_domain   = "example.com"
}

run "default_is_the_builtin_baseline_only" {
  command = plan

  assert {
    condition     = local.platform_https_domains == local.builtin_platform_https_domains && length(var.platform_https_domains) == 0
    error_message = "With no caller domains the platform baseline is exactly the built-in AWS/registry set."
  }
}

run "caller_domains_are_normalized_deduplicated_and_additive" {
  command = plan
  variables {
    cni             = "cilium"
    egress_firewall = { enabled = true, policies = { cluster = {} } }
    platform_https_domains = [
      "api.hub.example",
      " API.Hub.Example ",
      "loki.hub.example.",
      "registry-1.docker.io",
    ]
  }

  assert {
    condition     = local.platform_https_domains == setunion(local.builtin_platform_https_domains, ["api.hub.example", "loki.hub.example"])
    error_message = "Caller domains are lower-cased, trimmed of whitespace and trailing dots, de-duplicated against each other and the built-ins, and added to (never replacing) the built-in baseline."
  }

  assert {
    condition     = contains(output.egress_firewall.platform_baseline, "api.hub.example") && contains(output.egress_firewall.platform_baseline, "auth.docker.io")
    error_message = "platform_baseline reports both caller and built-in platform domains."
  }

  assert {
    condition = length([
      for rule in values(output.egress_firewall.effective_rules) :
      rule if rule.origin == "platform" && rule.source_class == "cluster" && rule.platform_required && rule.domain == "api.hub.example"
    ]) == 1 && length([for rule in values(output.egress_firewall.effective_rules) : rule if rule.origin == "platform"]) == length(local.platform_https_domains)
    error_message = "Each caller domain compiles to exactly one cluster-only rule with origin platform, alongside the built-in rules."
  }
}

run "caller_domains_do_not_reach_external_groups_sharing_the_cluster_policy" {
  command = plan
  variables {
    cni = "cilium"
    egress_firewall = {
      enabled = true
      policies = {
        cluster = {
          domain_allow = { example = { domains = ["example.com"], protocol = "https" } }
        }
      }
    }
    platform_https_domains   = ["api.hub.example"]
    additional_subnet_groups = [{ name = "external", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"] }]
    egress_attachments       = { external = { policy_key = "cluster", subnet_group_key = "external" } }
  }

  assert {
    condition = length(regexall(
      "pass tls .*10[.]0[.]0[.]0/20.*api[.]hub[.]example",
      module.egress_network[0].suricata_rules
      )) == 1 && length(regexall(
      "pass tls .*10[.]0[.]208[.]0/24.*api[.]hub[.]example",
      module.egress_network[0].suricata_rules
      )) == 0 && length(regexall(
      "pass tls .*10[.]0[.]208[.]0/24.*example[.]com",
      module.egress_network[0].suricata_rules
    )) == 1
    error_message = "A caller platform domain is compiled for cluster sources only; an external group on the same policy key gets the customer rules but not the platform baseline."
  }
}

run "caller_domains_are_accepted_but_inert_when_disabled" {
  command = plan
  variables {
    platform_https_domains = ["api.hub.example"]
  }

  assert {
    condition     = length(output.egress_firewall.platform_baseline) == 0 && length(module.egress_network) == 0
    error_message = "Disabled mode records no baseline and creates no firewall, whatever platform domains are supplied."
  }
}

run "scheme_is_rejected" {
  command = plan
  variables {
    platform_https_domains = ["https://api.hub.example"]
  }
  expect_failures = [var.platform_https_domains]
}

run "path_is_rejected" {
  command = plan
  variables {
    platform_https_domains = ["api.hub.example/oauth/v2/token"]
  }
  expect_failures = [var.platform_https_domains]
}

run "port_is_rejected" {
  command = plan
  variables {
    platform_https_domains = ["api.hub.example:8443"]
  }
  expect_failures = [var.platform_https_domains]
}

run "ip_literal_is_rejected" {
  command = plan
  variables {
    platform_https_domains = ["203.0.113.10"]
  }
  expect_failures = [var.platform_https_domains]
}

run "wildcard_is_rejected" {
  command = plan
  variables {
    platform_https_domains = ["*.hub.example"]
  }
  expect_failures = [var.platform_https_domains]
}

run "single_label_is_rejected" {
  command = plan
  variables {
    platform_https_domains = ["localhost"]
  }
  expect_failures = [var.platform_https_domains]
}

mock_provider "aws" {}

variables {
  name                  = "egress-provenance-test"
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
  platform_https_domains = ["registry.k8s.io"]
  cluster_policy_key     = "cluster"
  policies = {
    cluster = {
      domain_allow = {
        images = { domains = ["registry.k8s.io", "api.example.com"], protocol = "https" }
        plain  = { domains = ["registry.k8s.io"], protocol = "http" }
      }
      network_allow = {
        partner = { destination_ipv4_cidrs = ["8.8.8.8/32"], protocol = "tcp", destination_ports = [22], reason = "partner SFTP" }
      }
    }
    clients = { domain_allow = { images = { domains = ["registry.k8s.io"], protocol = "https" } } }
  }
}

# The platform baseline compiles to its own rules (cluster/platform/...); a
# customer rule naming the same host is a separate rule with its own identity.
run "customer_repeat_retains_platform_requirement" {
  command = plan

  assert {
    condition     = output.effective_rules["cluster/platform/https/443/registry.k8s.io"].origin == "platform" && output.effective_rules["cluster/platform/https/443/registry.k8s.io"].platform_required && output.effective_rules["cluster/platform/https/443/registry.k8s.io"].customer_configured
    error_message = "The platform rule must stay platform-required and record that the customer also configured the host."
  }

  assert {
    condition     = output.effective_rules["cluster/domain/images/https/443/registry.k8s.io"].origin == "customer" && output.effective_rules["cluster/domain/images/https/443/registry.k8s.io"].platform_required && output.effective_rules["cluster/domain/images/https/443/registry.k8s.io"].customer_configured
    error_message = "The customer's duplicate must be reported as customer-origin while flagging that the platform requires the host anyway."
  }

  assert {
    condition = alltrue([for identity in ["cluster/domain/images/https/443/api.example.com", "cluster/domain/plain/http/80/registry.k8s.io", "clients/domain/images/https/443/registry.k8s.io", "cluster/network/partner"] :
      output.effective_rules[identity].origin == "customer" && !output.effective_rules[identity].platform_required && output.effective_rules[identity].customer_configured
    ])
    error_message = "Platform provenance must not leak into customer-only domains, HTTP, external classes or network exceptions."
  }

  assert {
    condition     = length(regexall("pass tls \\[10[.]42[.]64[.]0/24\\].*registry[.]k8s[.]io", output.suricata_rules)) == 1 && length([for identity in keys(output.effective_rules) : identity if startswith(identity, "clients/platform/")]) == 0
    error_message = "External classes get only their own customer rule for a platform host, never the baseline."
  }
}

run "removing_customer_repeat_preserves_access" {
  command = plan
  variables {
    policies = {
      cluster = {
        domain_allow = {
          images = { domains = ["api.example.com"], protocol = "https" }
          plain  = { domains = ["registry.k8s.io"], protocol = "http" }
        }
        network_allow = {
          partner = { destination_ipv4_cidrs = ["8.8.8.8/32"], protocol = "tcp", destination_ports = [22], reason = "partner SFTP" }
        }
      }
      clients = { domain_allow = { images = { domains = ["registry.k8s.io"], protocol = "https" } } }
    }
  }

  assert {
    condition     = output.effective_rules["cluster/platform/https/443/registry.k8s.io"].origin == "platform" && output.effective_rules["cluster/platform/https/443/registry.k8s.io"].platform_required && !output.effective_rules["cluster/platform/https/443/registry.k8s.io"].customer_configured && !contains(keys(output.effective_rules), "cluster/domain/images/https/443/registry.k8s.io")
    error_message = "Removing the duplicated customer entry must leave the platform rule in place and clear only the customer flag."
  }

  assert {
    condition     = output.effective_rules["cluster/platform/https/443/registry.k8s.io"].sid == run.customer_repeat_retains_platform_requirement.effective_rules["cluster/platform/https/443/registry.k8s.io"].sid && length(regexall("pass tls \\[10[.]42[.]0[.]0/20\\].*content:\"registry[.]k8s[.]io\"; startswith", output.suricata_rules)) == 1
    error_message = "The platform rule's identity and SID must not change; the host stays allowed from the cluster."
  }
}

mock_provider "aws" {}

variables {
  name                  = "egress-rule-limit-test"
  vpc_id                = "vpc-test"
  vpc_cidr              = "10.42.0.0/16"
  igw_id                = "igw-test"
  azs                   = ["us-east-1a"]
  cluster_subnets_by_az = { us-east-1a = { subnet_id = "subnet-cluster", ipv4_cidr = "10.42.0.0/20", route_table_id = "rtb-cluster" } }
  firewall_subnet_cidrs = { us-east-1a = "10.42.240.0/28" }
  nat_subnet_cidrs      = { us-east-1a = "10.42.56.0/24" }
  cluster_policy_key    = "cluster"
  policies              = { cluster = {} }
}

run "expanded_rules_within_limit_are_accepted" {
  command = plan
  variables {
    cluster_source_cidrs_by_az = {
      us-east-1a = [for i in range(100) : cidrsubnet("10.42.128.0/17", 15, i)]
    }
    policies = { cluster = { domain_allow = { example = { domains = ["example.com"], protocol = "https" } } } }
  }
}

# With no customer pass rules, only the reserved drop rule can exceed the
# limit. Both occurrences of HOME_NET contribute to its expanded length.
run "reject_oversized_expanded_reserved_drop_rule" {
  command = plan
  variables {
    cluster_source_cidrs_by_az = {
      us-east-1a = [for i in range(300) : cidrsubnet("10.42.128.0/17", 15, i)]
    }
  }
  expect_failures = [terraform_data.contract]
}

# Here the expanded drop rule is below the limit. A valid maximum-length
# hostname makes the domain pass rule exceed it after HOME_NET expansion.
run "reject_oversized_expanded_domain_rule" {
  command = plan
  variables {
    cluster_source_cidrs_by_az = {
      us-east-1a = [for i in range(236) : cidrsubnet("10.42.128.0/17", 15, i)]
    }
    policies = {
      cluster = {
        domain_allow = {
          long = { domains = [join(".", [for size in [63, 63, 63, 61] : join("", [for i in range(size) : "a"])])], protocol = "https" }
        }
      }
    }
  }
  expect_failures = [terraform_data.contract]
}

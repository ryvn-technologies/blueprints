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

  # Only read for customer-provided subnets and the VPC they sit in.
  mock_data "aws_subnet" {
    defaults = {
      vpc_id                     = "vpc-0123456789abcdef0"
      owner_id                   = "123456789012"
      available_ip_address_count = 4000
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      cidr_block = "10.0.0.0/16"
      cidr_block_associations = [{
        association_id = "vpc-cidr-assoc-0123456789abcdef0"
        cidr_block     = "10.0.0.0/16"
        state          = "associated"
      }]
    }
  }

  mock_data "aws_route_table" {
    defaults = {
      routes = [{ cidr_block = "0.0.0.0/0" }]
    }
  }
}

mock_provider "random" {}
mock_provider "tls" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "cloudinit" {}

# No ryvn_init_image or cilium_chart_version: platform blueprints older than
# this module don't pass them, and vpc-cni plans must still succeed.
variables {
  environment_name     = "test"
  account_id           = "123456789012"
  internal_root_domain = "internal.example.com"
  public_root_domain   = "example.com"
}

run "default_adds_no_subnets" {
  command = plan

  assert {
    condition = alltrue([
      for domain in ["auth.docker.io", "registry-1.docker.io", "production.cloudflare.docker.com", "docker-images-prod.s3.dualstack.${var.region}.amazonaws.com"] :
      contains(local.platform_https_domains, domain)
    ])
    error_message = "The cluster platform baseline must permit Docker Hub image authentication, registry and layer requests."
  }

  assert {
    condition     = length(aws_subnet.additional_workload) == 0
    error_message = "The default must not add workload subnets."
  }

  assert {
    condition     = jsonencode(output.vpc.private_subnet_cidr_blocks) == jsonencode(["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"])
    error_message = "private_subnet_cidr_blocks changed: ${jsonencode(output.vpc.private_subnet_cidr_blocks)}"
  }
}

run "firewall_disabled_preserves_s3_gateway_and_nat" {
  command = plan

  assert {
    condition     = length(module.egress_network) == 0 && length(aws_vpc_endpoint.s3) == 1
    error_message = "Disabled firewall mode must retain the existing S3 gateway endpoint without creating firewall resources."
  }

  assert {
    condition     = output.egress_firewall.enabled == false && output.egress_firewall.attachments == {} && output.egress_firewall.effective_rules == {} && output.egress_firewall.firewall_arn == null && length(output.egress_firewall.protected_subnet_ids) == 0
    error_message = "Disabled mode must return the stable output object with enabled = false and empty diagnostics."
  }

  assert {
    condition     = length(module.vpc[0].natgw_ids) == 1
    error_message = "Disabled firewall mode must keep the VPC module's NAT gateway."
  }

  # The private default route is one root-owned resource in both modes so an
  # enable/disable flips it in place (ReplaceRoute) instead of racing a create
  # against a destroy of the same 0.0.0.0/0 route.
  assert {
    condition     = keys(aws_route.private_default) == ["0"] && aws_route.private_default["0"].vpc_endpoint_id == null && length(module.vpc[0].private_nat_gateway_route_ids) == 0
    error_message = "Disabled mode must own exactly one private default route (single NAT table) at the root, not inside the VPC module."
  }
}

run "disabled_firewall_rejects_attachments" {
  command = plan
  variables {
    additional_subnet_groups = [{ name = "external", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"] }]
    egress_attachments = {
      external = { policy_key = "cluster", subnet_group_key = "external" }
    }
  }
  expect_failures = [terraform_data.egress_firewall_compatibility]
}

# Network allocation is independent of the firewall: a group created in
# disabled mode gets its subnet, table and association but no default route.
run "disabled_firewall_still_allocates_groups_with_local_routing_only" {
  command = plan
  variables {
    additional_subnet_groups = [
      { name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] },
      { name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a", "us-east-1b"] },
    ]
  }
  assert {
    condition     = jsonencode([for k in ["api_clients/us-east-1a", "api_clients/us-east-1b", "api_clients/us-east-1c", "small_jobs/us-east-1a", "small_jobs/us-east-1b"] : module.workload_subnet_groups[0].geometry[split("/", k)[0]].cidrs_by_az[split("/", k)[1]]]) == jsonencode(["10.0.208.0/24", "10.0.209.0/24", "10.0.210.0/24", "10.0.211.0/26", "10.0.211.64/26"])
    error_message = "Default /16 geometry must match the documented example."
  }
  assert {
    condition     = length(aws_subnet.additional_workload) == 0 && jsonencode(output.vpc.private_subnet_cidr_blocks) == jsonencode(["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]) && keys(aws_route.private_default) == ["0"]
    error_message = "Groups must not change the legacy cluster allocation or default-off routing."
  }
  assert {
    condition     = length(module.egress_network) == 0
    error_message = "No firewall resources in disabled mode."
  }
  assert {
    condition     = length(module.workload_subnet_groups[0].subnet_ids) == 5
    error_message = "Five group subnets: ${jsonencode(keys(module.workload_subnet_groups[0].subnet_ids))}"
  }
  assert {
    condition     = jsonencode(keys(output.additional_subnet_groups)) == jsonencode(["api_clients", "small_jobs"]) && jsonencode(keys(output.additional_subnet_groups.small_jobs.subnets_by_az)) == jsonencode(["us-east-1a", "us-east-1b"]) && output.additional_subnet_groups.small_jobs.subnets_by_az["us-east-1b"].ipv4_cidr == "10.0.211.64/26"
    error_message = "Inventory output lists groups by name with one entry per AZ: ${jsonencode(keys(output.additional_subnet_groups))}"
  }
}

run "enabled_firewall_requires_cilium" {
  command = plan
  variables {
    egress_firewall = {
      enabled  = true
      policies = { cluster = {} }
    }
  }
  expect_failures = [terraform_data.egress_firewall_compatibility]
}

run "enabled_firewall_exposes_cni_and_protected_subnets" {
  command = plan
  variables {
    cni                  = "cilium"
    ryvn_init_image      = "ryvn/init:test"
    cilium_chart_version = "1.20.2"
    egress_firewall = {
      enabled  = true
      policies = { cluster = {} }
    }
  }
  assert {
    condition     = length(keys(output.egress_firewall.nat_route_table_ids)) == 3 && toset(output.egress_firewall.vpc_cidrs) == toset(["10.0.0.0/16"])
    error_message = "The output must expose one NAT route table per AZ and every VPC CIDR for audit."
  }
  assert {
    condition     = output.egress_firewall.cni == "cilium" && length(output.egress_firewall.cluster_subnet_ids) == 3
    error_message = "The output must expose the CNI and the protected cluster subnet IDs (Cilium eni.nodeSpec.subnetIDs)."
  }
  assert {
    condition     = length(output.egress_firewall.protected_subnet_ids) == 3 && length(output.egress_firewall.effective_rules) == length(local.platform_https_domains) && alltrue([for rule in values(output.egress_firewall.effective_rules) : rule.origin == "platform" && rule.source_class == "cluster"])
    error_message = "With no customer policy the effective rules are exactly the cluster platform baseline, and the protected pool is the three primary subnets."
  }
  assert {
    condition     = keys(aws_route.private_default) == ["0", "1", "2"] && alltrue([for route in values(aws_route.private_default) : route.nat_gateway_id == null]) && length(module.vpc[0].private_nat_gateway_route_ids) == 0
    error_message = "Enabled mode must own one root private default route per AZ table pointing at the firewall endpoint, with no NAT route from the VPC module."
  }
}

run "two_per_az_extends_protected_pool_and_reserves_growth" {
  command = plan
  variables {
    cni                     = "cilium"
    ryvn_init_image         = "ryvn/init:test"
    cilium_chart_version    = "1.20.2"
    workload_subnets_per_az = 2
    egress_firewall         = { enabled = true, policies = { cluster = {} } }
  }
  assert {
    condition     = length(output.egress_firewall.protected_subnet_ids) == 6 && length(output.egress_firewall.cluster_subnet_ids) == 3
    error_message = "Additional workload subnets join the protected pool without changing the primary EKS selector."
  }
  assert {
    condition     = toset(local.workload_subnet_cidrs_above_count) == toset(["10.0.112.0/20", "10.0.128.0/20", "10.0.144.0/20", "10.0.160.0/20", "10.0.176.0/20", "10.0.192.0/20"])
    error_message = "The not-yet-created growth slots handed to the module as reserved CIDRs must be exactly slots 7..12."
  }
}

run "unknown_attachment_group_is_rejected" {
  command = plan
  variables {
    cni                      = "cilium"
    ryvn_init_image          = "ryvn/init:test"
    cilium_chart_version     = "1.20.2"
    egress_firewall          = { enabled = true, policies = { cluster = {} } }
    additional_subnet_groups = [{ name = "external", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"] }]
    egress_attachments       = { external = { policy_key = "cluster", subnet_group_key = "nope" } }
  }
  expect_failures = [terraform_data.egress_firewall_compatibility]
}

run "retired_attachment_group_is_rejected" {
  command = plan
  variables {
    cni                      = "cilium"
    ryvn_init_image          = "ryvn/init:test"
    cilium_chart_version     = "1.20.2"
    egress_firewall          = { enabled = true, policies = { cluster = {} } }
    additional_subnet_groups = [{ name = "external", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"], retired = true }]
    egress_attachments       = { external = { policy_key = "cluster", subnet_group_key = "external" } }
  }
  expect_failures = [terraform_data.egress_firewall_compatibility]
}

run "duplicate_group_assignment_is_rejected_even_with_same_policy" {
  command = plan
  variables {
    cni                      = "cilium"
    ryvn_init_image          = "ryvn/init:test"
    cilium_chart_version     = "1.20.2"
    egress_firewall          = { enabled = true, policies = { cluster = {} } }
    additional_subnet_groups = [{ name = "external", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"] }]
    egress_attachments = {
      a = { policy_key = "cluster", subnet_group_key = "external" }
      b = { policy_key = "cluster", subnet_group_key = "external" }
    }
  }
  expect_failures = [terraform_data.egress_firewall_compatibility]
}

run "attached_group_is_routed_and_unattached_group_is_not" {
  command = plan
  variables {
    cni                  = "cilium"
    ryvn_init_image      = "ryvn/init:test"
    cilium_chart_version = "1.20.2"
    egress_firewall      = { enabled = true, policies = { cluster = {} } }
    additional_subnet_groups = [
      { name = "attached", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b"] },
      { name = "idle", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"] },
    ]
    egress_attachments = { attached = { policy_key = "cluster", subnet_group_key = "attached" } }
  }
  assert {
    condition     = toset(module.egress_network[0].home_net) == toset(["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20", "10.0.208.0/24", "10.0.209.0/24"])
    error_message = "HOME_NET is cluster plus attached group CIDRs only, never the unattached group: ${jsonencode(module.egress_network[0].home_net)}"
  }
  assert {
    condition     = length(regexall("10[.]0[.]210[.]0/24", module.egress_network[0].suricata_rules)) == 0
    error_message = "The unattached group has no source rules."
  }
  assert {
    condition     = length(output.egress_firewall.protected_subnet_ids) == 5 && jsonencode(keys(output.egress_firewall.attachments)) == jsonencode(["attached"]) && output.egress_firewall.attachments.attached.schema_version == 1 && jsonencode(keys(output.egress_firewall.attachments.attached.subnets_by_az)) == jsonencode(["us-east-1a", "us-east-1b"]) && output.egress_firewall.attachments.attached.subnets_by_az["us-east-1a"].ipv4_cidr == "10.0.208.0/24"
    error_message = "Protected pool = 3 cluster + 2 attached subnets; the version-1 descriptor carries one subnet per AZ."
  }
  assert {
    condition     = length(output.additional_subnet_groups) == 2
    error_message = "Inventory output lists attached and unattached groups alike."
  }
}

run "shared_policy_does_not_grant_platform_baseline_to_external" {
  command = plan
  variables {
    cni                  = "cilium"
    ryvn_init_image      = "ryvn/init:test"
    cilium_chart_version = "1.20.2"
    egress_firewall = {
      enabled            = true
      default_action     = "deny"
      cluster_policy_key = "shared"
      policies = {
        shared = { domain_allow = { example = { domains = ["example.com"], protocol = "https" } } }
      }
    }
    additional_subnet_groups = [{ name = "external", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"] }]
    egress_attachments = {
      external = { policy_key = "shared", subnet_group_key = "external" }
    }
  }

  assert {
    condition     = length(regexall("pass tls .*10[.]0[.]0[.]0/20.*auth[.]docker[.]io", module.egress_network[0].suricata_rules)) == 1 && length(regexall("pass tls .*10[.]0[.]208[.]0/24.*auth[.]docker[.]io", module.egress_network[0].suricata_rules)) == 0
    error_message = "A shared customer policy must not grant the cluster platform baseline to external sources."
  }
  assert {
    condition     = length(regexall("pass tls .*10[.]0[.]0[.]0/20.*example[.]com", module.egress_network[0].suricata_rules)) == 1 && length(regexall("pass tls .*10[.]0[.]208[.]0/24.*example[.]com", module.egress_network[0].suricata_rules)) == 1
    error_message = "Both source classes must retain their common customer allowances."
  }
  assert {
    condition     = length(output.egress_firewall.protected_subnet_ids) == 4 && output.egress_firewall.effective_rules["external/domain/example/https/443/example.com"].origin == "customer" && output.egress_firewall.effective_rules["cluster/domain/example/https/443/example.com"].origin == "customer" && output.egress_firewall.effective_rules["cluster/platform/https/443/auth.docker.io"].origin == "platform"
    error_message = "The attachment subnet joins the protected pool and effective_rules attributes provenance per source class."
  }
}

run "two_per_az_on_a_20_adds_the_next_three_24s" {
  command = plan

  variables {
    vpc_cidr                = "10.21.32.0/20"
    workload_subnets_per_az = 2
  }

  assert {
    condition = jsonencode({ for key, subnet in aws_subnet.additional_workload : key => [subnet.availability_zone, subnet.cidr_block] }) == jsonencode({
      "us-east-1a-2" = ["us-east-1a", "10.21.36.0/24"]
      "us-east-1b-2" = ["us-east-1b", "10.21.37.0/24"]
      "us-east-1c-2" = ["us-east-1c", "10.21.38.0/24"]
    })
    error_message = "Unexpected subnets: ${jsonencode({ for key, subnet in aws_subnet.additional_workload : key => subnet.cidr_block })}"
  }

  assert {
    condition = alltrue([
      for subnet in aws_subnet.additional_workload :
      subnet.tags["karpenter.sh/discovery"] == "ryvn-eks-test" &&
      subnet.tags["kubernetes.io/role/cni"] == "1" &&
      !contains(keys(subnet.tags), "kubernetes.io/role/internal-elb")
    ])
    error_message = "Added subnets need the Karpenter and CNI tags and must not carry the internal-elb tag."
  }

  assert {
    condition     = length(aws_route_table_association.additional_workload) == 3
    error_message = "Each added subnet needs a private route table association."
  }

  assert {
    condition     = length(output.vpc.private_subnet_ids) == 3 && length(output.vpc.private_subnet_cidr_blocks) == 6
    error_message = "private_subnet_ids must stay one per AZ and private_subnet_cidr_blocks must include the added subnets."
  }
}

run "four_per_az_on_a_16_uses_blocks_4_to_12" {
  command = plan

  variables {
    workload_subnets_per_az = 4
  }

  assert {
    condition = jsonencode(sort(values(aws_subnet.additional_workload)[*].cidr_block)) == jsonencode(sort([
      "10.0.64.0/20", "10.0.80.0/20", "10.0.96.0/20",
      "10.0.112.0/20", "10.0.128.0/20", "10.0.144.0/20",
      "10.0.160.0/20", "10.0.176.0/20", "10.0.192.0/20",
    ]))
    error_message = "Unexpected subnets: ${jsonencode(sort(values(aws_subnet.additional_workload)[*].cidr_block))}"
  }
}

run "cilium_requires_the_blueprint_versions" {
  command = plan

  variables {
    cni = "cilium"
  }

  expect_failures = [var.ryvn_init_image, var.cilium_chart_version]
}

run "cilium_finds_workload_subnets_by_tag" {
  command = plan

  variables {
    cni                  = "cilium"
    ryvn_init_image      = "ryvn/init:test"
    cilium_chart_version = "1.20.2"
  }

  assert {
    condition = jsonencode(local.cilium_values.eni.nodeSpec) == jsonencode({
      firstInterfaceIndex = 0
      subnetIDs           = []
      subnetTags          = ["karpenter.sh/discovery=ryvn-eks-test"]
    })
    error_message = "Unexpected Cilium subnet selection: ${jsonencode(local.cilium_values.eni.nodeSpec)}"
  }
}

run "cilium_finds_added_subnets_by_tag" {
  command = plan

  variables {
    cni                     = "cilium"
    ryvn_init_image         = "ryvn/init:test"
    cilium_chart_version    = "1.20.2"
    workload_subnets_per_az = 2
  }

  assert {
    condition = length(aws_subnet.additional_workload) == 3 && alltrue([
      for subnet in aws_subnet.additional_workload : alltrue([
        for key, value in local.workload_subnet_discovery_tags : lookup(subnet.tags, key, null) == value
      ])
    ])
    error_message = "Every added subnet must carry the tags Cilium finds workload subnets by."
  }
}

run "cilium_finds_customer_subnets_by_id" {
  command = plan

  variables {
    cni                          = "cilium"
    ryvn_init_image              = "ryvn/init:test"
    cilium_chart_version         = "1.20.2"
    existing_vpc_id              = "vpc-0123456789abcdef0"
    existing_workload_subnet_ids = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
    egress_mode                  = "nat_gateway"
  }

  override_data {
    target = data.aws_subnet.byo_provided_workload["subnet-0aaaaaaaaaaaaaaaa"]
    values = { availability_zone = "us-east-1a", cidr_block = "10.0.0.0/20", vpc_id = "vpc-0123456789abcdef0", available_ip_address_count = 4000 }
  }

  override_data {
    target = data.aws_subnet.byo_provided_workload["subnet-0bbbbbbbbbbbbbbbb"]
    values = { availability_zone = "us-east-1b", cidr_block = "10.0.16.0/20", vpc_id = "vpc-0123456789abcdef0", available_ip_address_count = 4000 }
  }

  override_data {
    target = data.aws_subnet.byo_provided_control_plane["subnet-0aaaaaaaaaaaaaaaa"]
    values = { availability_zone = "us-east-1a", cidr_block = "10.0.0.0/20", vpc_id = "vpc-0123456789abcdef0", available_ip_address_count = 4000 }
  }

  override_data {
    target = data.aws_subnet.byo_provided_control_plane["subnet-0bbbbbbbbbbbbbbbb"]
    values = { availability_zone = "us-east-1b", cidr_block = "10.0.16.0/20", vpc_id = "vpc-0123456789abcdef0", available_ip_address_count = 4000 }
  }

  assert {
    condition = jsonencode(local.cilium_values.eni.nodeSpec) == jsonencode({
      firstInterfaceIndex = 0
      subnetIDs           = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
      subnetTags          = []
    })
    error_message = "Unexpected Cilium subnet selection: ${jsonencode(local.cilium_values.eni.nodeSpec)}"
  }
}

run "lowering_fails_while_higher_subnets_exist" {
  command = plan

  variables {
    workload_subnets_per_az = 2
  }

  override_data {
    target = data.aws_subnets.workload_subnets_above_count[0]
    values = {
      ids = ["subnet-0a1b2c3d4e5f60718"]
    }
  }

  expect_failures = [data.aws_subnets.workload_subnets_above_count]
}

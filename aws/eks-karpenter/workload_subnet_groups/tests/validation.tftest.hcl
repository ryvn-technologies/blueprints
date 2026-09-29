mock_provider "aws" {}

variables {
  name     = "ryvn-test"
  vpc_id   = "vpc-test"
  vpc_cidr = "10.0.0.0/16"
  azs      = ["us-east-1a", "us-east-1b", "us-east-1c"]
  reserved_cidrs = [
    "10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20",
    "10.0.48.0/24", "10.0.49.0/24", "10.0.50.0/24",
    "10.0.52.0/24", "10.0.53.0/24", "10.0.54.0/24",
    "10.0.56.0/24", "10.0.57.0/24", "10.0.58.0/24",
    "10.0.60.0/28", "10.0.60.16/28", "10.0.60.32/28",
    "10.0.64.0/20", "10.0.80.0/20", "10.0.96.0/20",
  ]
  groups = [
    { name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] },
    { name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a", "us-east-1b"] },
  ]
}

# Stateless validation. Kept apart from allocation.tftest.hcl: its runs share
# one state, and plans that drop applied groups are blocked by prevent_destroy.


run "empty_default_creates_nothing" {
  command = plan
  variables { groups = [] }
  assert {
    condition     = length(aws_subnet.group) == 0 && length(terraform_data.geometry) == 0 && length(output.groups) == 0
    error_message = "default must allocate nothing"
  }
}

run "three_az_20_does_not_fit_default_16" {
  command = plan
  variables {
    groups = [{ name = "big", ipv4_prefix_length = 20, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] }]
  }
  expect_failures = [terraform_data.contract]
}

run "two_az_20_fits_default_16" {
  command = plan
  variables {
    groups = [{ name = "big", ipv4_prefix_length = 20, availability_zones = ["us-east-1a", "us-east-1b"] }]
  }
  assert {
    condition     = jsonencode(output.geometry.big.cidrs_by_az) == jsonencode({ us-east-1a = "10.0.208.0/20", us-east-1b = "10.0.224.0/20" })
    error_message = "two /20s fill blocks 13-14: ${jsonencode(output.geometry.big)}"
  }
}

run "alignment_spill_into_block_15_is_rejected" {
  command = plan
  variables {
    groups = [
      { name = "one", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"] },
      { name = "big", ipv4_prefix_length = 20, availability_zones = ["us-east-1a", "us-east-1b"] },
    ]
  }
  expect_failures = [terraform_data.contract]
}

run "prefix_out_of_bounds_is_rejected" {
  command = plan
  variables {
    groups = [
      { name = "tiny", ipv4_prefix_length = 29, availability_zones = ["us-east-1a"] },
      { name = "huge", ipv4_prefix_length = 19, availability_zones = ["us-east-1a"] },
      { name = "frac", ipv4_prefix_length = 24.5, availability_zones = ["us-east-1a"] },
    ]
  }
  expect_failures = [terraform_data.contract]
}

run "duplicate_and_reserved_names_are_rejected" {
  command = plan
  variables {
    groups = [
      { name = "cluster", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"] },
      { name = "dup", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"] },
      { name = "dup", ipv4_prefix_length = 24, availability_zones = ["us-east-1b"] },
    ]
  }
  expect_failures = [var.groups]
}

run "duplicate_or_empty_azs_are_rejected" {
  command = plan
  variables {
    groups = [
      { name = "twice", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1a"] },
      { name = "none", ipv4_prefix_length = 24, availability_zones = [] },
    ]
  }
  expect_failures = [var.groups]
}

run "az_outside_the_environment_is_rejected" {
  command = plan
  variables {
    groups = [{ name = "outside", ipv4_prefix_length = 24, availability_zones = ["us-west-2a"] }]
  }
  expect_failures = [terraform_data.contract]
}

run "overlap_with_reserved_infrastructure_is_rejected" {
  command = plan
  variables {
    reserved_cidrs = ["10.0.208.0/22"]
    groups         = [{ name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a"] }]
  }
  expect_failures = [terraform_data.contract]
}

run "larger_vpc_lower_bound_is_vpc_prefix_plus_4" {
  command = plan
  variables {
    vpc_cidr       = "10.0.0.0/8"
    reserved_cidrs = []
    groups         = [{ name = "wide", ipv4_prefix_length = 16, availability_zones = ["us-east-1a"] }]
  }
  assert {
    condition     = output.geometry.wide.cidrs_by_az["us-east-1a"] == "10.208.0.0/16"
    error_message = "a /8 VPC allocates /16 groups from block 13: ${jsonencode(output.geometry.wide)}"
  }
}

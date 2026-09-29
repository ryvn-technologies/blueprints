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

# --- stateful sequence: apply, append, retire, then rejected edits ---------

run "initial_apply_allocates_from_block_13" {
  command = apply

  assert {
    condition = jsonencode(output.geometry.api_clients.cidrs_by_az) == jsonencode({
      us-east-1a = "10.0.208.0/24", us-east-1b = "10.0.209.0/24", us-east-1c = "10.0.210.0/24"
    })
    error_message = "api_clients geometry: ${jsonencode(output.geometry.api_clients)}"
  }
  assert {
    condition     = jsonencode(output.geometry.small_jobs.cidrs_by_az) == jsonencode({ us-east-1a = "10.0.211.0/26", us-east-1b = "10.0.211.64/26" })
    error_message = "small_jobs geometry: ${jsonencode(output.geometry.small_jobs)}"
  }
  assert {
    condition     = output.geometry.api_clients.position == 0 && output.geometry.small_jobs.position == 1
    error_message = "positions must follow input order"
  }
  assert {
    condition     = length(aws_subnet.group) == 5 && length(aws_route_table.group) == 5 && length(aws_route_table_association.group) == 5
    error_message = "one subnet, route table and association per active group/AZ"
  }
  assert {
    condition     = toset(keys(aws_subnet.group)) == toset(["api_clients/us-east-1a", "api_clients/us-east-1b", "api_clients/us-east-1c", "small_jobs/us-east-1a", "small_jobs/us-east-1b"])
    error_message = "resource keys must be group-name/AZ: ${jsonencode(keys(aws_subnet.group))}"
  }
  assert {
    condition     = aws_subnet.group["small_jobs/us-east-1b"].cidr_block == terraform_data.geometry["small_jobs"].output.cidrs_by_az["us-east-1b"]
    error_message = "subnets must consume the guarded record's CIDRs"
  }
  assert {
    condition     = length(keys(output.groups.api_clients.subnets_by_az)) == 3 && length(keys(output.groups.small_jobs.subnets_by_az)) == 2
    error_message = "inventory output lists one placement per AZ"
  }
  assert {
    condition     = !contains(keys(aws_subnet.group["api_clients/us-east-1a"].tags), "karpenter.sh/discovery") && !contains(keys(aws_subnet.group["api_clients/us-east-1a"].tags), "kubernetes.io/role/cni") && length([for k in keys(aws_subnet.group["api_clients/us-east-1a"].tags) : k if startswith(k, "kubernetes.io/cluster/")]) == 0
    error_message = "external groups must not carry cluster/Karpenter/CNI discovery tags"
  }
  assert {
    condition     = jsonencode(output.active_cidrs) == jsonencode(["10.0.208.0/24", "10.0.209.0/24", "10.0.210.0/24", "10.0.211.0/26", "10.0.211.64/26"])
    error_message = "active_cidrs: ${jsonencode(output.active_cidrs)}"
  }
}

run "append_lexically_earlier_group_keeps_existing_allocations" {
  command = apply
  variables {
    groups = [
      { name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] },
      { name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a", "us-east-1b"] },
      { name = "aaa_batch", ipv4_prefix_length = 25, availability_zones = ["us-east-1c"] },
    ]
  }
  assert {
    condition     = output.geometry.api_clients.cidrs_by_az["us-east-1a"] == "10.0.208.0/24" && output.geometry.small_jobs.cidrs_by_az["us-east-1b"] == "10.0.211.64/26"
    error_message = "existing allocations changed after append"
  }
  assert {
    condition     = output.geometry.aaa_batch.cidrs_by_az["us-east-1c"] == "10.0.211.128/25" && output.geometry.aaa_batch.position == 2
    error_message = "appended group must take the next aligned space: ${jsonencode(output.geometry.aaa_batch)}"
  }
  assert {
    condition     = aws_subnet.group["api_clients/us-east-1a"].id == run.initial_apply_allocates_from_block_13.subnet_ids["api_clients/us-east-1a"]
    error_message = "appending a lexically earlier name must not replace existing subnets"
  }
}

run "retire_middle_group_preserves_span_and_record" {
  command = apply
  variables {
    groups = [
      { name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] },
      { name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a", "us-east-1b"], retired = true },
      { name = "aaa_batch", ipv4_prefix_length = 25, availability_zones = ["us-east-1c"] },
    ]
  }
  assert {
    condition     = !contains(keys(aws_subnet.group), "small_jobs/us-east-1a") && !contains(keys(output.groups), "small_jobs")
    error_message = "retired group must create no subnets or inventory"
  }
  assert {
    condition     = contains(keys(terraform_data.geometry), "small_jobs") && output.geometry.small_jobs.cidrs_by_az["us-east-1a"] == "10.0.211.0/26"
    error_message = "retired group keeps its allocation record"
  }
  assert {
    condition     = output.geometry.aaa_batch.cidrs_by_az["us-east-1c"] == "10.0.211.128/25" && aws_subnet.group["aaa_batch/us-east-1c"].id == run.append_lexically_earlier_group_keeps_existing_allocations.subnet_ids["aaa_batch/us-east-1c"]
    error_message = "retiring must not compact later allocations"
  }
  assert {
    condition     = !contains(output.active_cidrs, "10.0.211.0/26")
    error_message = "retired space must not be reported as active"
  }
}

run "resizing_a_surviving_group_is_rejected" {
  command = plan
  variables {
    groups = [
      { name = "api_clients", ipv4_prefix_length = 23, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] },
      { name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a", "us-east-1b"], retired = true },
      { name = "aaa_batch", ipv4_prefix_length = 25, availability_zones = ["us-east-1c"] },
    ]
  }
  expect_failures = [terraform_data.geometry]
}

run "reordering_groups_is_rejected" {
  command = plan
  variables {
    groups = [
      { name = "aaa_batch", ipv4_prefix_length = 25, availability_zones = ["us-east-1c"] },
      { name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] },
      { name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a", "us-east-1b"], retired = true },
    ]
  }
  expect_failures = [terraform_data.geometry]
}

run "reordering_azs_is_rejected" {
  command = plan
  variables {
    groups = [
      { name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1b", "us-east-1a", "us-east-1c"] },
      { name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a", "us-east-1b"], retired = true },
      { name = "aaa_batch", ipv4_prefix_length = 25, availability_zones = ["us-east-1c"] },
    ]
  }
  expect_failures = [terraform_data.geometry]
}

run "adding_an_az_to_a_surviving_group_is_rejected" {
  command = plan
  variables {
    groups = [
      { name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] },
      { name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a", "us-east-1b"], retired = true },
      { name = "aaa_batch", ipv4_prefix_length = 25, availability_zones = ["us-east-1c", "us-east-1a"] },
    ]
  }
  expect_failures = [terraform_data.geometry]
}

# Un-retiring is not blocked by the guard: it recreates subnets in the same
# recorded span, which the plan shows as creates (no other group can have
# taken that space).
run "unretiring_recreates_the_same_cidrs" {
  command = plan
  variables {
    groups = [
      { name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] },
      { name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a", "us-east-1b"] },
      { name = "aaa_batch", ipv4_prefix_length = 25, availability_zones = ["us-east-1c"] },
    ]
  }
  assert {
    condition     = aws_subnet.group["small_jobs/us-east-1a"].cidr_block == "10.0.211.0/26" && output.geometry.aaa_batch.cidrs_by_az["us-east-1c"] == "10.0.211.128/25"
    error_message = "un-retired group must come back in its recorded span without moving others"
  }
}

run "unchanged_config_plans_no_changes_after_retire" {
  command = plan
  variables {
    groups = [
      { name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] },
      { name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a", "us-east-1b"], retired = true },
      { name = "aaa_batch", ipv4_prefix_length = 25, availability_zones = ["us-east-1c"] },
    ]
  }
  assert {
    condition     = length(aws_subnet.group) == 4
    error_message = "steady state keeps four active subnets"
  }
}

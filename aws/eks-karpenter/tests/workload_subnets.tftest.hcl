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

run "default_adds_no_subnets" {
  command = plan

  assert {
    condition     = length(aws_subnet.additional_workload) == 0
    error_message = "The default must not add workload subnets."
  }

  assert {
    condition     = jsonencode(output.vpc.private_subnet_cidr_blocks) == jsonencode(["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"])
    error_message = "private_subnet_cidr_blocks changed: ${jsonencode(output.vpc.private_subnet_cidr_blocks)}"
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

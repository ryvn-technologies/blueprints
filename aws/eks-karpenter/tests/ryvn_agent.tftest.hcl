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

  # ryvn-init's CodeBuild subnets must be owned by this account.
  mock_data "aws_subnet" {
    defaults = {
      owner_id = "123456789012"
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

run "vpc_cni_without_the_bootstrap_has_no_ryvn_init" {
  command = plan

  assert {
    condition     = length(module.ryvn_init) == 0
    error_message = "Without Cilium or ryvn_agent_bootstrap there is nothing for ryvn-init to do."
  }

  assert {
    condition     = output.ryvn_agent_bootstrapped == false
    error_message = "Ryvn must keep installing the agent itself."
  }
}

run "the_bootstrap_runs_ryvn_init_on_a_vpc_cni_cluster" {
  command = plan

  variables {
    ryvn_init_image = "ryvn/init:test"
    ryvn_agent_bootstrap = {
      hub_url       = "https://hub.example.invalid"
      token_version = 1
    }
    ryvn_agent_bootstrap_token = "pending"
  }

  override_resource {
    target          = aws_iam_role.ryvn_agent_role
    override_during = plan
    values          = { arn = "arn:aws:iam::123456789012:role/RyvnAgentRole-test" }
  }

  assert {
    condition     = length(module.ryvn_init) == 1
    error_message = "ryvn_agent_bootstrap must run ryvn-init on a VPC CNI cluster."
  }

  assert {
    condition     = output.ryvn_agent_bootstrapped
    error_message = "Ryvn must skip its own agent install."
  }

  assert {
    condition = jsonencode(local.ryvn_agent_values) == jsonencode({
      serviceAccount = { annotations = { "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/RyvnAgentRole-test" } }
    })
    error_message = "ryvn-init needs the agent's role, which the hub can't know during the apply: ${jsonencode(local.ryvn_agent_values)}"
  }
}

run "the_bootstrap_requires_ryvn_init_image" {
  command = plan

  variables {
    ryvn_agent_bootstrap = {
      hub_url       = "https://hub.example.invalid"
      token_version = 1
    }
    ryvn_agent_bootstrap_token = "pending"
  }

  expect_failures = [var.ryvn_init_image]
}

run "the_bootstrap_needs_an_account_that_can_create_keys" {
  command = plan

  variables {
    ryvn_init_image        = "ryvn/init:test"
    create_cluster_kms_key = false
    ryvn_agent_bootstrap = {
      hub_url       = "https://hub.example.invalid"
      token_version = 1
    }
    ryvn_agent_bootstrap_token = "pending"
  }

  expect_failures = [var.ryvn_agent_bootstrap]
}

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

run "vpc_cni_without_ryvn_agent_has_no_ryvn_init" {
  command = plan

  assert {
    condition     = length(module.ryvn_init) == 0
    error_message = "Without Cilium or ryvn_agent there is nothing for ryvn-init to do."
  }
}

run "ryvn_agent_values_are_the_given_values_plus_the_cluster_details" {
  command = plan

  variables {
    ryvn_init_image = "ryvn/init:test"
    ryvn_agent = {
      repository    = "oci://registry.example.invalid/charts"
      chart         = "ryvn-agent"
      chart_version = "0.14.1"
      values = {
        i2gw           = { enabled = true }
        serviceAccount = { annotations = { "example.invalid/team" = "platform" } }
      }
    }
  }

  override_resource {
    target          = aws_iam_role.ryvn_agent_role
    override_during = plan
    values          = { arn = "arn:aws:iam::123456789012:role/RyvnAgentRole-test" }
  }

  assert {
    condition     = length(module.ryvn_init) == 1
    error_message = "ryvn_agent must run ryvn-init on a VPC CNI cluster."
  }

  assert {
    condition = jsonencode(local.ryvn_agent_values) == jsonencode({
      i2gw = { enabled = true }
      serviceAccount = { annotations = {
        "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/RyvnAgentRole-test"
        "example.invalid/team"       = "platform"
      } }
      targetEnv = "test"
    })
    error_message = "Unexpected ryvn-agent values: ${jsonencode(local.ryvn_agent_values)}"
  }
}

run "ryvn_agent_requires_ryvn_init_image" {
  command = plan

  variables {
    ryvn_agent = {
      repository    = "oci://registry.example.invalid/charts"
      chart         = "ryvn-agent"
      chart_version = "0.14.1"
    }
  }

  expect_failures = [var.ryvn_init_image]
}

run "ryvn_agent_values_cannot_set_the_target_environment" {
  command = plan

  variables {
    ryvn_init_image = "ryvn/init:test"
    ryvn_agent = {
      repository    = "oci://registry.example.invalid/charts"
      chart         = "ryvn-agent"
      chart_version = "0.14.1"
      values        = { targetEnv = "other" }
    }
  }

  expect_failures = [var.ryvn_agent]
}

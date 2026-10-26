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
  ryvn_init_image      = "ryvn/init:test"
  cilium_chart_version = "1.20.2"
  cilium_values        = {}
}

run "default_policy_is_broad_allow_with_denies" {
  command = plan

  assert {
    condition = (
      length(jsondecode(aws_iam_policy.ryvn_agent_permissions.policy).Statement) == 2 &&
      jsondecode(aws_iam_policy.ryvn_agent_permissions.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_policy.ryvn_agent_permissions.policy).Statement[0].Action == ["*"] &&
      jsondecode(aws_iam_policy.ryvn_agent_permissions.policy).Statement[1].Effect == "Deny"
    )
    error_message = "With no executor policies the agent gets the broad allow and the sensitive-action deny list."
  }
}

run "executor_policies_are_the_entire_policy" {
  command = plan
  variables {
    terraform_executor_policies = [
      {
        effect    = "Allow"
        actions   = ["s3:CreateBucket"]
        resources = ["arn:aws:s3:::example-*"]
      },
    ]
  }

  assert {
    condition = jsondecode(aws_iam_policy.ryvn_agent_permissions.policy).Statement == [
      {
        Effect   = "Allow"
        Action   = ["s3:CreateBucket"]
        Resource = ["arn:aws:s3:::example-*"]
      },
    ]
    error_message = "Caller-supplied executor policies replace the default outright; nothing (including IAM role management) is added on top."
  }
}

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
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
    defaults = { issuer_arn = "arn:aws:iam::123456789012:role/test" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_subnets" {
    defaults = { ids = [] }
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

run "default_preserves_all_control_plane_logs" {
  command = plan

  assert {
    condition     = toset(output.control_plane_logging.enabled_log_types) == toset(["api", "audit", "authenticator", "controllerManager", "scheduler"])
    error_message = "Omitting enabled_log_types must preserve all five control-plane log types."
  }
}

run "audit_free_environment_reports_selected_logs" {
  command = plan
  variables {
    enabled_log_types = ["api", "authenticator", "controllerManager", "scheduler"]
  }

  assert {
    condition     = toset(output.control_plane_logging.enabled_log_types) == toset(["api", "authenticator", "controllerManager", "scheduler"])
    error_message = "Audit discovery must report the environment's selected log types."
  }
}

run "reject_unsupported_log_type" {
  command = plan
  variables {
    enabled_log_types = ["invalid"]
  }
  expect_failures = [var.enabled_log_types]
}

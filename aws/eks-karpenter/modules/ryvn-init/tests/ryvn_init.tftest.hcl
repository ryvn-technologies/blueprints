mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }

  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }

  mock_data "aws_subnet" {
    defaults = { owner_id = "123456789012" }
  }
}

variables {
  environment_name                   = "test"
  cluster_name                       = "ryvn-eks-test"
  cluster_endpoint                   = "https://example.invalid"
  cluster_certificate_authority_data = "dGVzdA=="
  cluster_security_group_id          = "sg-0123456789abcdef0"
  vpc_id                             = "vpc-0123456789abcdef0"
  subnet_ids                         = ["subnet-0123456789abcdef0"]
  image                              = "ryvn/init:test"
}

run "ryvn_agent_without_cilium" {
  command = plan

  variables {
    ryvn_agent = {
      repository    = "oci://registry.example.invalid/charts"
      chart         = "ryvn-agent"
      chart_version = "0.14.1"
      values        = { targetEnv = "test" }
    }
  }

  assert {
    condition = jsonencode(yamldecode(local.config_document)) == jsonencode({
      aws       = { bootstrapResultSsmParameter = "/ryvn/test/ryvn-init/result", eksClusterName = "ryvn-eks-test", region = "us-east-1" }
      cluster   = { apiServerEndpoint = "https://example.invalid", certificateAuthorityData = "dGVzdA==" }
      ryvnAgent = { chart = "ryvn-agent", chartVersion = "0.14.1", install = true, repository = "oci://registry.example.invalid/charts", values = { targetEnv = "test" } }
      timeout   = "780s"
    })
    error_message = "Unexpected ryvn-init configuration:\n${local.config_document}"
  }
}

run "cilium_then_ryvn_agent" {
  command = plan

  variables {
    cilium = {
      chart_version = "1.20.2"
      values        = { ipam = { mode = "eni" } }
    }
    ryvn_agent = {
      repository    = "oci://registry.example.invalid/charts"
      chart         = "ryvn-agent"
      chart_version = "0.14.1"
      values        = { targetEnv = "test" }
    }
  }

  assert {
    condition     = yamldecode(local.config_document).cilium.install && yamldecode(local.config_document).ryvnAgent.install
    error_message = "Both steps must be in the ryvn-init configuration:\n${local.config_document}"
  }
}

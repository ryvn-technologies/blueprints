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
  executor_principal_arn             = "arn:aws:iam::123456789012:role/RyvnAccessRole"
}

run "cilium_only_keeps_the_document_existing_clusters_ran" {
  command = plan

  variables {
    cilium = {
      chart_version = "1.20.2"
      values        = { ipam = { mode = "eni" } }
    }
  }

  assert {
    condition = jsonencode(yamldecode(local.config_document)) == jsonencode({
      aws     = { bootstrapResultSsmParameter = "/ryvn/test/ryvn-init/result", eksClusterName = "ryvn-eks-test", region = "us-east-1" }
      cilium  = { chartVersion = "1.20.2", install = true, migrationTimeout = "10800s", repair = false, values = { ipam = { mode = "eni" } } }
      cluster = { apiServerEndpoint = "https://example.invalid", certificateAuthorityData = "dGVzdA==" }
      timeout = "780s"
    })
    error_message = "An existing cluster's document changed, which reruns ryvn-init:\n${local.config_document}"
  }

  assert {
    condition     = local.build_timeout_minutes == 208
    error_message = "An existing cluster's build timeout changed: ${local.build_timeout_minutes}."
  }

  assert {
    condition     = length(aws_ssm_parameter.agent_bootstrap_token) == 0 && length(aws_kms_key.agent_bootstrap_token) == 0
    error_message = "Without ryvn_agent there is no token to store."
  }
}

run "ryvn_agent_without_cilium" {
  command = plan

  variables {
    ryvn_agent = {
      hub_url       = "https://hub.example.invalid"
      token_version = 1
      values        = { serviceAccount = { annotations = { "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/RyvnAgentRole-test" } } }
    }
    ryvn_agent_bootstrap_token = "pending"
  }

  assert {
    condition = jsonencode(yamldecode(local.config_document)) == jsonencode({
      aws = {
        agentBootstrapTokenSsmParameter = "/ryvn/test/ryvn-init/agent-bootstrap-token"
        bootstrapResultSsmParameter     = "/ryvn/test/ryvn-init/result"
        eksClusterName                  = "ryvn-eks-test"
        region                          = "us-east-1"
      }
      cluster = { apiServerEndpoint = "https://example.invalid", certificateAuthorityData = "dGVzdA==" }
      ryvnAgent = {
        hubUrl  = "https://hub.example.invalid"
        install = true
        values  = { serviceAccount = { annotations = { "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/RyvnAgentRole-test" } } }
      }
      timeout = "780s"
    })
    error_message = "Unexpected ryvn-init configuration:\n${local.config_document}"
  }

  assert {
    condition     = local.build_timeout_minutes == 15
    error_message = "A run for the agent alone needs its 10 minutes and CodeBuild's 5, not ${local.build_timeout_minutes}."
  }

  assert {
    condition     = aws_ssm_parameter.agent_bootstrap_token[0].type == "SecureString" && aws_ssm_parameter.agent_bootstrap_token[0].value_wo_version == 1
    error_message = "The token must be a SecureString written by token_version."
  }
}

run "only_the_executor_and_ryvn_init_can_use_the_token_key" {
  command = plan

  variables {
    ryvn_agent = {
      hub_url       = "https://hub.example.invalid"
      token_version = 1
      values        = {}
    }
    ryvn_agent_bootstrap_token = "pending"
  }

  override_resource {
    target          = aws_iam_role.codebuild_service
    override_during = plan
    values          = { arn = "arn:aws:iam::123456789012:role/RyvnInitRole-test" }
  }

  override_data {
    target          = data.aws_region.current
    override_during = plan
    values          = { region = "us-east-1" }
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_kms_key.agent_bootstrap_token[0].policy).Statement :
      statement.Sid != "ManageKey" || !anytrue([
        for action in statement.Action : contains(["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*", "kms:Create*", "kms:CreateGrant"], action)
      ])
    ])
    error_message = "The account may manage the key, but not use it."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_kms_key.agent_bootstrap_token[0].policy).Statement :
      statement.Sid != "ExecutorWritesToken" || (
        statement.Condition.ArnEquals["aws:PrincipalArn"] == "arn:aws:iam::123456789012:role/RyvnAccessRole" &&
        statement.Condition.StringEquals["kms:ViaService"] == "ssm.us-east-1.amazonaws.com"
      )
    ])
    error_message = "Only the executor may write the token, through SSM, and it must be matched by ARN so a recreated role keeps access."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_kms_key.agent_bootstrap_token[0].policy).Statement :
      statement.Sid != "RyvnInitReadsToken" || (
        statement.Principal.AWS == "arn:aws:iam::123456789012:role/RyvnInitRole-test" &&
        statement.Action == ["kms:Decrypt"] &&
        statement.Condition.StringEquals["kms:ViaService"] == "ssm.us-east-1.amazonaws.com"
      )
    ])
    error_message = "Only ryvn-init may read the token, through SSM."
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
      hub_url       = "https://hub.example.invalid"
      token_version = 1
      values        = {}
    }
    ryvn_agent_bootstrap_token = "pending"
  }

  assert {
    condition     = yamldecode(local.config_document).cilium.install && yamldecode(local.config_document).ryvnAgent.install
    error_message = "Both steps must be in the ryvn-init configuration:\n${local.config_document}"
  }

  assert {
    condition     = local.build_timeout_minutes == 218
    error_message = "The build must outlast both steps, not ${local.build_timeout_minutes} minutes."
  }
}

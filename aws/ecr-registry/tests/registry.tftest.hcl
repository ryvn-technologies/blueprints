mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_eks_node_groups" {
    defaults = {
      names = ["system", "apps"]
    }
  }

  mock_data "aws_eks_node_group" {
    defaults = {
      node_role_arn = "arn:aws:iam::123456789012:role/prod-eks-node"
    }
  }

  mock_data "aws_iam_role" {
    defaults = {
      name = "prod-eks-node"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/ryvn/registries/mock-role"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/ryvn/registries/mock-policy"
    }
  }
}

mock_provider "random" {
  mock_resource "random_id" {
    defaults = {
      hex = "abcd1234"
    }
  }
}

variables {
  aws_region            = "us-east-1"
  environment           = "prod"
  cluster_name          = "prod-eks"
  push_namespace        = "ryvn"
  push_service_accounts = ["mirror-sync"]
}

run "detects_node_roles_from_managed_node_groups" {
  command = plan

  assert {
    condition     = tolist(local.node_role_names) == tolist(["prod-eks-node"])
    error_message = "Node roles from all managed node groups must be collected and de-duplicated."
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.node_pull) == 1
    error_message = "Exactly one pull attachment per distinct node role is expected."
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.push) == 1
    error_message = "Each copier service account must get a pod identity association."
  }
}

run "explicit_node_roles_are_merged_with_detected_ones" {
  command = plan

  variables {
    node_role_names = ["prod-eks", "prod-eks-node"]
  }

  assert {
    condition     = toset(local.node_role_names) == toset(["prod-eks", "prod-eks-node"])
    error_message = "Karpenter node roles passed explicitly must be merged with detected node group roles without duplicates."
  }
}

run "agent_pull_role_is_granted_reader" {
  command = plan

  variables {
    pull_role_arns = ["arn:aws:iam::123456789012:role/ryvn-agent-abc"]
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.node_pull) == 2
    error_message = "The read-only ECR policy must attach to both node and agent roles."
  }

  assert {
    condition     = contains(keys(aws_iam_role_policy_attachment.node_pull), "ryvn-agent-abc")
    error_message = "The read-only ECR policy must create an attachment keyed by the role name derived from the agent ARN."
  }

  assert {
    condition     = contains(output.pull_identity.roleNames, "ryvn-agent-abc")
    error_message = "The pull identity output must include the effective agent role."
  }
}

run "explicit_node_roles_skip_cluster_lookup" {
  command = plan

  variables {
    cluster_name    = ""
    node_role_names = ["attached-node-role"]
  }

  assert {
    condition     = length(data.aws_eks_node_groups.this) == 0
    error_message = "Attached clusters must not trigger an EKS node group lookup."
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.push) == 0
    error_message = "Pod identity associations require an EKS cluster name; attached clusters bind the role themselves."
  }
}

run "path_qualified_node_role_arns_resolve_to_the_role_name" {
  command = plan

  override_data {
    target = data.aws_eks_node_group.this["system"]
    values = {
      node_role_arn = "arn:aws:iam::123456789012:role/eks/nodes/prod-eks-node"
    }
  }

  assert {
    condition     = tolist(local.node_role_names) == tolist(["prod-eks-node"])
    error_message = "Roles created with an IAM path must resolve to the final ARN component."
  }
}

run "registry_name_is_normalised_for_ecr" {
  command = apply

  variables {
    registry_name = "Payments Mirror/EU!"
  }

  assert {
    condition     = local.repository_prefix == "payments-mirror-eu-abcd1234"
    error_message = "Registry names must be lowercased, have invalid characters replaced, and keep the random suffix."
  }
}

run "punctuation_only_registry_name_falls_back_to_a_valid_prefix" {
  command = apply

  variables {
    registry_name = "!!!"
  }

  assert {
    condition     = local.repository_prefix == "registry-abcd1234"
    error_message = "A name that sanitises to nothing must fall back to a valid base."
  }
}

run "null_explicit_node_identities_fall_back_to_detection" {
  command = plan

  variables {
    node_role_names = null
  }

  assert {
    condition     = tolist(local.node_role_names) == tolist(["prod-eks-node"])
    error_message = "A null node_role_names (rendered from an empty blueprint list) must behave like an empty list and keep detected identities."
  }
}

run "fails_without_any_node_identity" {
  command = plan

  variables {
    cluster_name = ""
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}

run "push_and_pull_policies_are_scoped_to_the_prefix" {
  command = apply

  assert {
    condition = alltrue([
      for s in jsondecode(local.push_policy).Statement :
      s.Sid == "Login" || s.Resource == "arn:aws:ecr:us-east-1:123456789012:repository/registry-abcd1234/*"
    ])
    error_message = "Every push statement except the login token must be scoped to the repository prefix."
  }

  assert {
    condition = !anytrue([
      for s in jsondecode(local.pull_policy).Statement :
      contains(s.Action, "ecr:PutImage") || contains(s.Action, "ecr:CreateRepository") || contains(s.Action, "ecr:DeleteRepository")
    ])
    error_message = "The node pull policy must not grant write or delete actions."
  }

  assert {
    condition = !anytrue([
      for s in jsondecode(local.push_policy).Statement :
      contains(s.Action, "ecr:DeleteRepository") || contains(s.Action, "ecr:BatchDeleteImage")
    ])
    error_message = "The push policy must not be able to delete mirrored artifacts."
  }
}

run "without_hub_principal_registry_uses_cluster_default" {
  command = apply

  assert {
    condition     = output.registry_host == "123456789012.dkr.ecr.us-east-1.amazonaws.com"
    error_message = "Registry host must be derived from account and region."
  }

  assert {
    condition     = output.destination_base == "123456789012.dkr.ecr.us-east-1.amazonaws.com/registry-abcd1234"
    error_message = "destination_base must be <host>/<prefix>."
  }

  assert {
    condition     = output.registry_definition.type == "genericContainerRegistry" && output.registry_definition.credentials.type == "clusterDefault"
    error_message = "Without a hub principal the registry must be exposed with clusterDefault credentials."
  }

  assert {
    condition     = length(aws_iam_role.hub_read) == 0
    error_message = "No hub role may be created without a hub principal."
  }
}

run "with_hub_principal_registry_uses_assume_role" {
  command = apply

  variables {
    hub_principal_arn = "arn:aws:iam::999999999999:role/ryvn-hub"
  }

  assert {
    condition     = output.registry_definition.type == "elasticContainerRegistry" && output.registry_definition.credentials.type == "assumeRole"
    error_message = "With a hub principal the registry must be exposed as ECR with assumeRole credentials."
  }

  assert {
    condition     = output.registry_definition.credentials.roleArn == output.hub_read_role_arn && output.hub_read_role_arn != ""
    error_message = "The assumeRole ARN must reference the hub read role."
  }
}

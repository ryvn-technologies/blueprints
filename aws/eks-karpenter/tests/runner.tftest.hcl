mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-gov-west-1" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws-us-gov" }
  }
}

variables {
  name_prefix               = "ryvn"
  cluster_name              = "example"
  cluster_security_group_id = "sg-00000000000000001"
  vpc_id                    = "vpc-00000000000000001"
  tags                      = { Environment = "example" }
}

run "runner_can_reach_eks_with_its_instance_profile" {
  command = plan

  module {
    source = "./modules/runner"
  }

  variables {
    name_prefix                  = "sg"
    iam_permissions_boundary_arn = "arn:aws-us-gov:iam::123456789012:policy/boundary"
  }

  override_resource {
    target          = aws_security_group.runner
    override_during = plan
    values          = { id = "sg-00000000000000002" }
  }
  override_resource {
    target          = aws_iam_role.runner
    override_during = plan
    values          = { arn = "arn:aws-us-gov:iam::123456789012:role/runner" }
  }
  override_resource {
    target          = aws_iam_instance_profile.runner
    override_during = plan
    values          = { arn = "arn:aws-us-gov:iam::123456789012:instance-profile/cluster-bootstrap/runner/sg.runner-example" }
  }
  override_resource {
    target          = aws_launch_template.runner
    override_during = plan
    values          = { id = "lt-00000000000000001" }
  }

  assert {
    condition     = length(coalesce(aws_iam_instance_profile.runner.tags, tomap({}))) == 0
    error_message = "Creating the runner instance profile must not require IAM tagging permissions."
  }

  assert {
    condition = (
      aws_iam_role.runner.name == "sg.runner-${substr(sha256("us-gov-west-1/example"), 0, 16)}" &&
      aws_iam_instance_profile.runner.path == "/cluster-bootstrap/runner/" &&
      aws_iam_instance_profile.runner.name == aws_iam_role.runner.name &&
      aws_security_group.runner.name == aws_iam_role.runner.name &&
      aws_launch_template.runner.name == aws_iam_role.runner.name
    )
    error_message = "Runner names must use the hub prefix. The instance profile must use the reserved bootstrap path."
  }

  assert {
    condition = (
      one(jsondecode(aws_iam_role.runner.assume_role_policy).Statement).Principal == { Service = "ec2.amazonaws.com" } &&
      aws_iam_role.runner.permissions_boundary == var.iam_permissions_boundary_arn &&
      aws_iam_instance_profile.runner.role == aws_iam_role.runner.name &&
      one(aws_launch_template.runner.iam_instance_profile).arn == aws_iam_instance_profile.runner.arn &&
      aws_eks_access_entry.runner.principal_arn == aws_iam_role.runner.arn &&
      aws_eks_access_entry.runner.cluster_name == var.cluster_name &&
      aws_eks_access_policy_association.runner.principal_arn == aws_iam_role.runner.arn &&
      aws_eks_access_policy_association.runner.policy_arn == "arn:aws-us-gov:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" &&
      one(aws_eks_access_policy_association.runner.access_scope).type == "cluster"
    )
    error_message = "The instance profile must identify the boundary-constrained role authorized to bootstrap this cluster."
  }

  assert {
    condition = anytrue([
      for mapping in aws_launch_template.runner.block_device_mappings :
      tobool(one(mapping.ebs).encrypted) if mapping.device_name == "/dev/xvda"
    ])
    error_message = "The runner launch template must encrypt the root volume."
  }

  assert {
    condition = (
      one(aws_launch_template.runner.metadata_options).http_tokens == "required" &&
      aws_security_group.runner.vpc_id == var.vpc_id &&
      aws_launch_template.runner.vpc_security_group_ids == toset([aws_security_group.runner.id]) &&
      aws_vpc_security_group_egress_rule.runner_https.security_group_id == aws_security_group.runner.id &&
      aws_vpc_security_group_egress_rule.runner_https.ip_protocol == "tcp" &&
      aws_vpc_security_group_egress_rule.runner_https.from_port == 443 &&
      aws_vpc_security_group_egress_rule.runner_https.to_port == 443 &&
      aws_vpc_security_group_egress_rule.runner_https.cidr_ipv4 == "0.0.0.0/0" &&
      aws_vpc_security_group_ingress_rule.cluster_api_from_runner.security_group_id == var.cluster_security_group_id &&
      aws_vpc_security_group_ingress_rule.cluster_api_from_runner.referenced_security_group_id == aws_security_group.runner.id &&
      aws_vpc_security_group_ingress_rule.cluster_api_from_runner.from_port == 443 &&
      aws_vpc_security_group_ingress_rule.cluster_api_from_runner.to_port == 443 &&
      aws_vpc_security_group_ingress_rule.cluster_api_from_runner.ip_protocol == "tcp"
    )
    error_message = "The runner must require IMDSv2 and use the group allowed to reach the cluster on TCP 443."
  }

  assert {
    condition = toset([
      for rule in aws_vpc_security_group_egress_rule.runner_dns : rule.ip_protocol
      if rule.security_group_id == aws_security_group.runner.id &&
      rule.from_port == 53 && rule.to_port == 53 && rule.cidr_ipv4 == "0.0.0.0/0"
    ]) == toset(["tcp", "udp"])
    error_message = "The runner must reach custom IPv4 DNS servers on port 53 over both TCP and UDP."
  }

  assert {
    condition     = output.launch_template_id == "lt-00000000000000001"
    error_message = "launch_template_id must return the EC2 launch template ID."
  }

  assert {
    condition = toset(flatten([
      for policy in jsondecode(file("${path.module}/../../permissions/cloudformation-access-role-byo-vpc.json")).Resources.RyvnAccessRole.Properties.Policies : [
        for statement in policy.PolicyDocument.Statement : statement.Action
        if try(
          statement.Effect == "Allow" &&
          statement.Resource["Fn::Sub"] == "arn:$${AWS::Partition}:ec2:$${AWS::Region}:$${AWS::AccountId}:instance/*" &&
          statement.Condition.ArnLike["ec2:InstanceProfile"]["Fn::Sub"] == "arn:$${AWS::Partition}:iam::$${AWS::AccountId}:instance-profile${aws_iam_instance_profile.runner.path}*",
          false
        )
      ]
    ])) == toset(["ec2:RunInstances", "ec2:TerminateInstances"])
    error_message = "The BYO VPC access role must use the runner's profile path for both instance launch and termination."
  }
}

run "create_runner_before_hub_upgrade" {
  command = apply

  module {
    source = "./modules/runner"
  }

  plan_options {
    target = [aws_iam_instance_profile.runner]
  }

  assert {
    condition     = startswith(aws_iam_role.runner.name, "ryvn-runner-") && aws_iam_instance_profile.runner.path == "/cluster-bootstrap/runner/"
    error_message = "An older hub must use the default runner name prefix and the reserved bootstrap path."
  }
}

run "hub_upgrade_preserves_runner_role" {
  command = plan

  module {
    source = "./modules/runner"
  }

  plan_options {
    target = [aws_iam_instance_profile.runner]
  }
  variables {
    name_prefix = "example"
  }

  assert {
    condition     = aws_iam_role.runner.name == "ryvn-runner-${substr(sha256("us-gov-west-1/example"), 0, 16)}" && aws_iam_instance_profile.runner.path == "/cluster-bootstrap/runner/"
    error_message = "When the upgraded hub first supplies its prefix, the runner must keep its original EKS role and profile path."
  }
}

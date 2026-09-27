data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_subnet" "codebuild" {
  count = length(var.subnet_ids)
  id    = var.subnet_ids[count.index]
}

locals {
  name       = "ryvn-init-${var.environment_name}"
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  # Built from the name: the service role's trust policy needs it before the project exists.
  project_arn = "arn:${local.partition}:codebuild:${local.region}:${local.account_id}:project/${local.name}"

  result_parameter = "/ryvn/${var.environment_name}/ryvn-init/result"
  result_succeeded = "succeeded"

  queued_timeout_minutes = 5
  # Headroom for CodeBuild to start an instance and pull the image.
  build_timeout_minutes = ceil(var.timeout_seconds / 60) + 5

  shared_subnet_ids = [for subnet in data.aws_subnet.codebuild : subnet.id if subnet.owner_id != local.account_id]

  config_document = yamlencode({
    timeout = "${var.timeout_seconds}s"
    cluster = {
      apiServerEndpoint        = var.cluster_endpoint
      certificateAuthorityData = var.cluster_certificate_authority_data
    }
    cilium = {
      install      = true
      chartVersion = var.cilium.chart_version
      values       = var.cilium.values
      repair       = var.cilium.repair
    }
    aws = {
      region                      = local.region
      eksClusterName              = var.cluster_name
      bootstrapResultSsmParameter = local.result_parameter
    }
  })
}

resource "aws_iam_role" "codebuild_service" {
  name                 = substr("RyvnInitRole-${var.environment_name}", 0, 64)
  permissions_boundary = var.iam_permissions_boundary_arn
  tags                 = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
          ArnLike = {
            "aws:SourceArn" = local.project_arn
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "codebuild_service" {
  name = substr("RyvnInitPolicy-${var.environment_name}", 0, 128)
  role = aws_iam_role.codebuild_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:ListAddons"]
        Resource = "arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${var.cluster_name}"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = aws_ssm_parameter.result.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.codebuild.arn}:*"
      },
      # CodeBuild's documented permissions for builds in a VPC:
      # https://docs.aws.amazon.com/codebuild/latest/userguide/auth-and-access-control-iam-identity-based-access-control.html#customer-managed-policies-example-create-vpc-network-interface
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeDhcpOptions",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeVpcs"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateNetworkInterfacePermission"]
        Resource = "arn:${local.partition}:ec2:${local.region}:${local.account_id}:network-interface/*"
        Condition = {
          StringEquals = {
            "ec2:AuthorizedService" = "codebuild.amazonaws.com"
          }
          ArnEquals = {
            "ec2:Subnet" = [for subnet_id in var.subnet_ids : "arn:${local.partition}:ec2:${local.region}:${local.account_id}:subnet/${subnet_id}"]
          }
        }
      }
    ]
  })
}

resource "aws_eks_access_entry" "codebuild_service" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.codebuild_service.arn
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "codebuild_service_cluster_admin" {
  cluster_name  = var.cluster_name
  principal_arn = aws_eks_access_entry.codebuild_service.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/ryvn/${var.environment_name}/ryvn-init"
  retention_in_days = 90
  tags              = var.tags
}

# ryvn-init overwrites this on every run. A failure shows up as drift, and the
# reset replaces terraform_data.run_trigger, so the next apply reruns the build.
resource "aws_ssm_parameter" "result" {
  name           = local.result_parameter
  type           = "String"
  insecure_value = local.result_succeeded
  tags           = var.tags
}

resource "aws_security_group" "codebuild" {
  name        = local.name
  description = "Ryvn cluster bootstrap"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = local.name })
}

resource "aws_vpc_security_group_egress_rule" "codebuild_all" {
  security_group_id = aws_security_group.codebuild.id
  description       = "Cluster API, AWS APIs, DNS and registries"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "cluster_api_from_codebuild" {
  security_group_id            = var.cluster_security_group_id
  referenced_security_group_id = aws_security_group.codebuild.id
  description                  = "Ryvn cluster bootstrap to the Kubernetes API"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  tags                         = var.tags
}

resource "aws_codebuild_project" "ryvn_init" {
  name           = local.name
  description    = "Bootstraps Ryvn components on EKS cluster ${var.cluster_name}"
  service_role   = aws_iam_role.codebuild_service.arn
  build_timeout  = local.build_timeout_minutes
  queued_timeout = local.queued_timeout_minutes
  tags           = var.tags

  source {
    type = "NO_SOURCE"
    # CodeBuild ignores the image's entrypoint.
    buildspec = yamlencode({
      version = "0.2"
      phases  = { build = { commands = ["/ryvn-init"] } }
    })
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type                        = "LINUX_CONTAINER"
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.image
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "RYVN_INIT_CONFIG"
      value = local.config_document
    }
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.subnet_ids
    security_group_ids = [aws_security_group.codebuild.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild.name
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.shared_subnet_ids) == 0
      error_message = "These subnets are shared from another AWS account: ${join(", ", local.shared_subnet_ids)}. Use subnets owned by this account."
    }
  }

  # CodeBuild checks the role's VPC permissions when it saves the project.
  depends_on = [aws_iam_role_policy.codebuild_service]
}

action "aws_codebuild_start_build" "ryvn_init" {
  config {
    project_name = aws_codebuild_project.ryvn_init.name
    timeout      = (local.queued_timeout_minutes + local.build_timeout_minutes) * 60

    # Only runs started by Terraform exit 0 after recording a failure, so a run
    # started by hand still shows as failed in CodeBuild.
    environment_variables_override {
      name  = "RYVN_INIT_EXIT_ZERO_ON_FAILURE"
      value = "true"
      type  = "PLAINTEXT"
    }
  }
}

resource "terraform_data" "run_trigger" {
  input = {
    config = local.config_document
    image  = var.image
  }

  lifecycle {
    replace_triggered_by = [aws_ssm_parameter.result]

    action_trigger {
      events  = [before_create, before_update]
      actions = [action.aws_codebuild_start_build.ryvn_init]
    }
  }

  depends_on = [
    aws_ssm_parameter.result,
    aws_iam_role_policy.codebuild_service,
    aws_eks_access_policy_association.codebuild_service_cluster_admin,
    aws_vpc_security_group_ingress_rule.cluster_api_from_codebuild,
    aws_vpc_security_group_egress_rule.codebuild_all,
  ]
}

data "aws_ssm_parameter" "result" {
  name = aws_ssm_parameter.result.name

  lifecycle {
    postcondition {
      condition     = self.insecure_value == local.result_succeeded
      error_message = "Cluster bootstrap failed: ${trimprefix(self.insecure_value, "failed: ")}. Logs: CloudWatch log group ${aws_cloudwatch_log_group.codebuild.name}."
    }
  }

  depends_on = [terraform_data.run_trigger]
}

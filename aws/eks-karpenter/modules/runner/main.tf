data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  # EC2 reserves names beginning with "sg-" for security group IDs.
  runner_name_base = var.name_prefix == "sg" ? "sg.runner" : "${var.name_prefix}-runner"

  # IAM names are account-wide. Include the region in the cluster fingerprint.
  runner_name = "${local.runner_name_base}-${substr(sha256("${data.aws_region.current.region}/${var.cluster_name}"), 0, 16)}"
}

resource "aws_iam_role" "runner" {
  name                 = local.runner_name
  permissions_boundary = var.iam_permissions_boundary_arn
  tags                 = var.tags

  # EKS binds the role ID. Keep the original role for the life of the cluster.
  lifecycle {
    ignore_changes = [name]
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "runner" {
  name = aws_iam_role.runner.name
  path = "/cluster-bootstrap/runner/"
  role = aws_iam_role.runner.name

  # Leave existing profile tags alone so updates also work without IAM tagging permissions.
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_eks_access_entry" "runner" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.runner.arn
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "runner" {
  cluster_name  = aws_eks_access_entry.runner.cluster_name
  principal_arn = aws_eks_access_entry.runner.principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_security_group" "runner" {
  name        = aws_iam_role.runner.name
  description = "Security group for runner VMs"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_egress_rule" "runner_https" {
  security_group_id = aws_security_group.runner.id
  description       = "Cluster API, hub and registries"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  tags              = var.tags
}

resource "aws_vpc_security_group_egress_rule" "runner_dns" {
  for_each = toset(["tcp", "udp"])

  security_group_id = aws_security_group.runner.id
  description       = "Allow outbound DNS to any IPv4 address"
  ip_protocol       = each.value
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "0.0.0.0/0"
  tags              = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "cluster_api_from_runner" {
  security_group_id            = var.cluster_security_group_id
  referenced_security_group_id = aws_security_group.runner.id
  description                  = "Runner access to the Kubernetes API"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  tags                         = var.tags
}

# Each task supplies its own subnet, instance tags and user data at launch.
resource "aws_launch_template" "runner" {
  name                   = aws_iam_role.runner.name
  update_default_version = true
  image_id               = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
  instance_type          = "t3.small"
  vpc_security_group_ids = [aws_security_group.runner.id]
  tags                   = var.tags

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      encrypted = true
    }
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.runner.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}

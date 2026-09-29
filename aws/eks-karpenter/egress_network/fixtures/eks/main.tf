terraform {
  required_version = ">= 1.5.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.28.0, != 6.57.0, < 7.0.0" }
  }
}

provider "aws" { region = var.region }

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" { type = string }
variable "operator_cidr" { type = string }

data "aws_caller_identity" "current" {}

locals {
  tags = {
    Name    = var.name
    Purpose = "disposable-egress-validation"
    Session = "cbc097828e5240688de052db9547e10f"
  }
  ssm_domains = ["ssm.${var.region}.amazonaws.com", "ssmmessages.${var.region}.amazonaws.com", "ec2messages.${var.region}.amazonaws.com"]
}

module "cluster" {
  source                               = "../../.."
  environment_name                     = var.name
  region                               = var.region
  account_id                           = data.aws_caller_identity.current.account_id
  vpc_cidr                             = "10.202.0.0/16"
  internal_root_domain                 = "validation.internal.invalid"
  public_root_domain                   = "validation.public.invalid"
  skip_dns_provisioning                = true
  create_cluster_kms_key               = false
  cluster_bootstrap_perms              = true
  provisioner_egress_cidrs             = [var.operator_cidr]
  cluster_endpoint_public_access_cidrs = []
  create_s3_gateway_endpoint           = false
  cluster_addons = {
    vpc-cni = { configuration_values = jsonencode({ enableNetworkPolicy = "true" }) }
  }
  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.large", "t3a.large", "m5.large", "m5a.large"]
      capacity_type  = "SPOT"
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      ami_type       = "AL2023_x86_64_STANDARD"
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }
  additional_subnet_groups = [
    { name = "external", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  ]
  egress_attachments = {
    external = { policy_key = "shared", subnet_group_key = "external" }
  }
  egress_firewall = {
    enabled            = true
    default_action     = "deny"
    cluster_policy_key = "shared"
    policies = {
      shared = {
        domain_allow = {
          probe = { domains = concat(["example.com", "*.example.org"], local.ssm_domains), protocol = "https" }
          plain = { domains = ["example.net"], protocol = "http" }
        }
      }
    }
  }
}

output "cluster_name" { value = module.cluster.cluster_name }
output "egress_firewall" { value = module.cluster.egress_firewall }
output "outbound_ips" { value = module.cluster.outbound_ips }
output "private_subnet_ids" { value = module.cluster.vpc.private_subnet_ids }

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "external_probe" {
  name   = "${var.name}-external-probe"
  vpc_id = module.cluster.vpc.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_iam_role" "external_probe" {
  name               = "${var.name}-external-probe"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "external_probe" {
  role       = aws_iam_role.external_probe.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "external_probe" {
  name = "${var.name}-external-probe"
  role = aws_iam_role.external_probe.name
  tags = local.tags
}

resource "aws_instance" "external_probe" {
  for_each                    = module.cluster.egress_firewall.attachments.external.subnets_by_az
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = "t3.micro"
  subnet_id                   = each.value.subnet_id
  vpc_security_group_ids      = [aws_security_group.external_probe.id]
  iam_instance_profile        = aws_iam_instance_profile.external_probe.name
  associate_public_ip_address = false
  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type = "one-time"
    }
  }
  tags       = merge(local.tags, { Name = "${var.name}-external-${each.key}" })
  depends_on = [aws_iam_role_policy_attachment.external_probe]
}

output "external_probe_ids" { value = { for az, probe in aws_instance.external_probe : az => probe.id } }

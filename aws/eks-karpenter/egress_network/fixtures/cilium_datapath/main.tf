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

# Operator address allowed to reach the EKS public endpoint (helm/kubectl).
variable "operator_cidr" { type = string }

variable "cluster_version" {
  type    = string
  default = "1.34"
}

# Nodes without a CNI never become Ready, so the managed node group would time
# out. The fixture therefore has an explicit boundary: apply with nodes off,
# install Cilium from the operator machine, apply again with nodes on. This
# is a test-only stand-in for the ryvn-init CodeBuild launcher (PR #8916); it
# validates the candidate datapath, not the Ryvn bootstrap.
variable "nodes_enabled" {
  type    = bool
  default = false
}

# Optional coverage: also offer the secondary-CIDR pod subnets to Cilium ENI
# allocation. The #8916 target allocates pod ENIs from the workload (node)
# subnets only, so this is off by default.
variable "secondary_pod_enis" {
  type    = bool
  default = false
}

# Additional TLS SNI exceptions for hosted add-ons under test (AWS Load
# Balancer Controller API endpoints, Tailscale coordination/DERP hosts).
# Kept explicit so the report can list the exact dependency inventory.
variable "extra_https_domains" {
  type    = list(string)
  default = []
}

variable "change_protection" {
  type    = bool
  default = true
}

data "aws_caller_identity" "current" {}

# Three AZs. Primary CIDR carries node, public (NLB), NAT and firewall
# subnets; the secondary CGNAT CIDR carries one /18 pod subnet per AZ as
# optional secondary-CIDR coverage. Pod and node subnets of an AZ share one
# route table. Cilium selects ENI subnets by the karpenter.sh/discovery tag,
# as ryvn_init.tf does at #8916.
locals {
  azs       = ["${var.region}a", "${var.region}b", "${var.region}c"]
  primary   = "10.205.0.0/16"
  secondary = "100.64.0.0/16"
  tags      = { Name = var.name, Purpose = "disposable-egress-validation", Session = "cc2a2d8a82cc41ab84e1420f14da2493" }
  discovery = { "karpenter.sh/discovery" = var.name }

  # Hosts the EKS node, Cilium images and coredns need; platform_https_domains
  # in the root module carries the non-Cilium part of this list today.
  platform_https_domains = [
    "api.ecr.${var.region}.amazonaws.com",
    "*.dkr.ecr.${var.region}.amazonaws.com",
    "s3.${var.region}.amazonaws.com",
    "prod-${var.region}-starport-layer-bucket.s3.${var.region}.amazonaws.com",
    "ec2.${var.region}.amazonaws.com",
    "ec2messages.${var.region}.amazonaws.com",
    "eks.${var.region}.amazonaws.com",
    "eks-auth.${var.region}.amazonaws.com",
    "eks-auth.${var.region}.api.aws",
    "sts.${var.region}.amazonaws.com",
    "ssm.${var.region}.amazonaws.com",
    "ssmmessages.${var.region}.amazonaws.com",
    "public.ecr.aws",
    "d2glxqk2uabbnd.cloudfront.net",
    "registry.k8s.io",
    "quay.io",
    "*.quay.io",
  ]
}

resource "aws_vpc" "validation" {
  cidr_block           = local.primary
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = local.tags
}

resource "aws_vpc_ipv4_cidr_block_association" "pods" {
  vpc_id     = aws_vpc.validation.id
  cidr_block = local.secondary
}

resource "aws_internet_gateway" "validation" {
  vpc_id = aws_vpc.validation.id
  tags   = local.tags
}

resource "aws_subnet" "cluster" {
  for_each          = { for i, az in local.azs : az => i }
  vpc_id            = aws_vpc.validation.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(local.primary, 4, each.value)
  tags = merge(local.tags, local.discovery, {
    Name                                = "${var.name}-node-${each.key}"
    "kubernetes.io/cluster/${var.name}" = "shared"
    "kubernetes.io/role/internal-elb"   = "1"
  })
}

resource "aws_subnet" "pods" {
  for_each          = { for i, az in local.azs : az => i }
  vpc_id            = aws_vpc.validation.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(aws_vpc_ipv4_cidr_block_association.pods.cidr_block, 2, each.value)
  tags = merge(local.tags, var.secondary_pod_enis ? local.discovery : {}, {
    Name = "${var.name}-pods-${each.key}"
  })
}

resource "aws_subnet" "public" {
  for_each                = { for i, az in local.azs : az => i }
  vpc_id                  = aws_vpc.validation.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(local.primary, 8, 48 + each.value)
  map_public_ip_on_launch = true
  tags = merge(local.tags, {
    Name                                = "${var.name}-public-${each.key}"
    "kubernetes.io/cluster/${var.name}" = "shared"
    "kubernetes.io/role/elb"            = "1"
  })
}

resource "aws_route_table" "cluster" {
  for_each = toset(local.azs)
  vpc_id   = aws_vpc.validation.id
  tags     = merge(local.tags, { Name = "${var.name}-cluster-${each.key}" })
}

resource "aws_route_table_association" "cluster" {
  for_each       = toset(local.azs)
  subnet_id      = aws_subnet.cluster[each.key].id
  route_table_id = aws_route_table.cluster[each.key].id
}

resource "aws_route_table_association" "pods" {
  for_each       = toset(local.azs)
  subnet_id      = aws_subnet.pods[each.key].id
  route_table_id = aws_route_table.cluster[each.key].id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.validation.id
  tags   = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.validation.id
}

resource "aws_route_table_association" "public" {
  for_each       = toset(local.azs)
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

module "network" {
  source            = "../.."
  name              = var.name
  vpc_id            = aws_vpc.validation.id
  vpc_cidr          = aws_vpc.validation.cidr_block
  vpc_cidrs         = [aws_vpc.validation.cidr_block, aws_vpc_ipv4_cidr_block_association.pods.cidr_block]
  change_protection = var.change_protection
  igw_id            = aws_internet_gateway.validation.id
  azs               = local.azs
  tags              = local.tags
  cluster_subnets_by_az = {
    for az in local.azs : az => {
      subnet_id      = aws_subnet.cluster[az].id
      ipv4_cidr      = aws_subnet.cluster[az].cidr_block
      route_table_id = aws_route_table.cluster[az].id
    }
  }
  cluster_source_cidrs_by_az = { for az in local.azs : az => [aws_subnet.pods[az].cidr_block] }
  reserved_subnet_cidrs      = [for az in local.azs : aws_subnet.public[az].cidr_block]
  firewall_subnet_cidrs      = { for i, az in local.azs : az => cidrsubnet(local.primary, 12, 960 + i) }
  nat_subnet_cidrs           = { for i, az in local.azs : az => cidrsubnet(local.primary, 8, 56 + i) }
  platform_https_domains     = concat(local.platform_https_domains, var.extra_https_domains)
  cluster_policy_key         = "cluster"
  policies = {
    cluster = {
      domain_allow  = { probe = { domains = ["example.com"], protocol = "https" } }
      network_allow = {}
    }
  }
  depends_on = [aws_route_table_association.cluster, aws_route_table_association.pods]
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = ">= 21.16.1, < 22.0"

  name               = var.name
  kubernetes_version = var.cluster_version

  vpc_id                   = aws_vpc.validation.id
  subnet_ids               = module.network.cluster_subnet_ids
  control_plane_subnet_ids = module.network.cluster_subnet_ids

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = [var.operator_cidr]
  enable_irsa                  = true
  create_kms_key               = false
  encryption_config            = null

  enable_cluster_creator_admin_permissions = true

  # No VPC CNI (the module disables EKS self-managed add-on bootstrap);
  # kube-proxy stays, as kubeProxyReplacement is off at #8916. coredns only
  # once nodes exist, otherwise the add-on never reaches ACTIVE.
  addons = merge(
    { kube-proxy = {}, eks-pod-identity-agent = {} },
    var.nodes_enabled ? { coredns = {} } : {}
  )

  node_security_group_additional_rules = {
    ingress_nlb_probe = {
      description = "public NLB IP targets (client IP preserved)"
      protocol    = "tcp"
      from_port   = 8080
      to_port     = 8080
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }
    ingress_vpc_all = {
      description = "pod ENIs and nodes within the VPC"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      cidr_blocks = [local.primary, local.secondary]
    }
  }

  eks_managed_node_groups = var.nodes_enabled ? {
    system = {
      instance_types = ["t3.large", "t3a.large", "m5.large", "m5a.large"]
      capacity_type  = "SPOT"
      min_size       = 3
      max_size       = 4
      desired_size   = 3
      ami_type       = "AL2023_x86_64_STANDARD"
      subnet_ids     = module.network.cluster_subnet_ids
      taints = {
        cilium = {
          key    = "node.cilium.io/agent-not-ready"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs         = { volume_size = 20, volume_type = "gp3", encrypted = true, delete_on_termination = true }
        }
      }
    }
  } : {}

  tags = local.tags
}

# Same trust and action set as the root module's cilium_operator_role (iam.tf).
resource "aws_iam_role" "cilium_operator" {
  name = "${var.name}-cilium-operator"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:cilium-operator"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "cilium_operator" {
  name = "${var.name}-cilium-operator"
  role = aws_iam_role.cilium_operator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:AttachNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*:*:network-interface/*"
      }
    ]
  })
}

# Public NLB with IP targets on port 8080; pod IPs are registered at test
# time from the operator machine to exercise the public-LB reply path.
resource "aws_lb" "public" {
  name               = substr("${var.name}-nlb", 0, 32)
  internal           = false
  load_balancer_type = "network"
  subnets            = [for az in local.azs : aws_subnet.public[az].id]
  tags               = local.tags
}

resource "aws_lb_target_group" "pods" {
  name        = substr("${var.name}-pods", 0, 32)
  port        = 8080
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.validation.id
  health_check {
    protocol = "TCP"
    port     = "8080"
  }
  tags = local.tags
}

resource "aws_lb_listener" "pods" {
  load_balancer_arn = aws_lb.public.arn
  port              = 8080
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.pods.arn
  }
}

output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cilium_operator_role_arn" { value = aws_iam_role.cilium_operator.arn }
output "cluster_subnet_ids" { value = module.network.cluster_subnet_ids }
output "pod_subnet_ids" { value = { for az in local.azs : az => aws_subnet.pods[az].id } }
output "cluster_route_table_ids" { value = { for az in local.azs : az => aws_route_table.cluster[az].id } }
output "nat_route_table_ids" { value = module.network.nat_route_table_ids }
output "nat_local_routes" { value = module.network.nat_local_routes }
output "home_net" { value = module.network.home_net }
output "firewall_arn" { value = module.network.firewall_arn }
output "firewall_endpoint_ids" { value = module.network.firewall_endpoint_ids }
output "alert_log_group" { value = module.network.alert_log_group }
output "flow_log_group" { value = module.network.flow_log_group }
output "nlb_dns_name" { value = aws_lb.public.dns_name }
output "target_group_arn" { value = aws_lb_target_group.pods.arn }

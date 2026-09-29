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

variable "name" {
  type = string
}

# Mirrors the production default: teardown requires an apply with false first.
variable "change_protection" {
  type    = bool
  default = true
}

# One AZ, a primary VPC CIDR for nodes and a secondary CGNAT CIDR for the
# planned Cilium pod subnets. The pod subnet shares the node route table, as
# the Cilium plan's per-AZ pod subnets will, and is declared as a cluster
# source so the firewall sees it as HOME_NET and gets a NAT return route.
locals {
  az          = "${var.region}a"
  primary     = "10.204.0.0/16"
  secondary   = "100.64.0.0/16"
  tags        = { Name = var.name, Purpose = "disposable-egress-validation", Session = "cc2a2d8a82cc41ab84e1420f14da2493" }
  ssm_domains = ["ssm.${var.region}.amazonaws.com", "ssmmessages.${var.region}.amazonaws.com", "ec2messages.${var.region}.amazonaws.com"]
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
  vpc_id            = aws_vpc.validation.id
  availability_zone = local.az
  cidr_block        = cidrsubnet(local.primary, 4, 0)
  tags              = local.tags
}

resource "aws_subnet" "pods" {
  vpc_id            = aws_vpc.validation.id
  availability_zone = local.az
  cidr_block        = cidrsubnet(aws_vpc_ipv4_cidr_block_association.pods.cidr_block, 2, 0)
  tags              = merge(local.tags, { "ryvn.ai/cilium-pod-subnet" = "true" })
}

resource "aws_route_table" "cluster" {
  vpc_id = aws_vpc.validation.id
  tags   = local.tags
}

resource "aws_route_table_association" "cluster" {
  subnet_id      = aws_subnet.cluster.id
  route_table_id = aws_route_table.cluster.id
}

resource "aws_route_table_association" "pods" {
  subnet_id      = aws_subnet.pods.id
  route_table_id = aws_route_table.cluster.id
}

module "network" {
  source            = "../.."
  name              = var.name
  vpc_id            = aws_vpc.validation.id
  vpc_cidr          = aws_vpc.validation.cidr_block
  vpc_cidrs         = [aws_vpc.validation.cidr_block, aws_vpc_ipv4_cidr_block_association.pods.cidr_block]
  change_protection = var.change_protection
  igw_id            = aws_internet_gateway.validation.id
  azs               = [local.az]
  tags              = local.tags
  cluster_subnets_by_az = {
    (local.az) = {
      subnet_id      = aws_subnet.cluster.id
      ipv4_cidr      = aws_subnet.cluster.cidr_block
      route_table_id = aws_route_table.cluster.id
    }
  }
  cluster_source_cidrs_by_az = { (local.az) = [aws_subnet.pods.cidr_block] }
  firewall_subnet_cidrs      = { (local.az) = cidrsubnet(local.primary, 12, 960) }
  nat_subnet_cidrs           = { (local.az) = cidrsubnet(local.primary, 8, 56) }
  cluster_policy_key         = "cluster"
  policies = {
    cluster = {
      domain_allow  = { probe = { domains = concat(["example.com"], local.ssm_domains), protocol = "https" } }
      network_allow = {}
    }
  }
  depends_on = [aws_route_table_association.cluster, aws_route_table_association.pods]
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "probe" {
  name   = "${var.name}-probe"
  vpc_id = aws_vpc.validation.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_iam_role" "probe" {
  name               = "${var.name}-probe"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.probe.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "probe" {
  name = "${var.name}-probe"
  role = aws_iam_role.probe.name
  tags = local.tags
}

# Both probes stand in for cluster sources: one on the node subnet, one on the
# secondary-CIDR pod subnet. Neither runs Cilium; they test routing and
# HOME_NET coverage of the secondary range, not the CNI.
resource "aws_instance" "probe" {
  for_each                    = { node = module.network.cluster_subnet_ids[0], pod = aws_subnet.pods.id }
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = "t3.micro"
  subnet_id                   = each.value
  vpc_security_group_ids      = [aws_security_group.probe.id]
  iam_instance_profile        = aws_iam_instance_profile.probe.name
  associate_public_ip_address = false
  tags                        = merge(local.tags, { Name = "${var.name}-${each.key}" })
  depends_on                  = [aws_iam_role_policy_attachment.ssm, module.network]
}

output "probe_instance_ids" { value = { for key, probe in aws_instance.probe : key => probe.id } }
output "probe_private_ips" { value = { for key, probe in aws_instance.probe : key => probe.private_ip } }
output "nat_route_table_ids" { value = module.network.nat_route_table_ids }
output "nat_local_routes" { value = module.network.nat_local_routes }
output "home_net" { value = module.network.home_net }
output "firewall_arn" { value = module.network.firewall_arn }
output "alert_log_group" { value = module.network.alert_log_group }
output "flow_log_group" { value = module.network.flow_log_group }

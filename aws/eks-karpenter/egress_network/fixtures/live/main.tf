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

variable "extra_https_domains" {
  type    = set(string)
  default = []
}

variable "allow_raw_ip" {
  type    = bool
  default = false
}

# Experiment only (not part of the supported module or root): adopt the AWS-created
# VPC-local route of every NAT table into a standalone aws_route owner and point it at
# the AZ firewall endpoint. Phase boundary: the NAT tables must already exist in state
# before their implicit routes can be imported, so the first apply runs with this false
# and the second apply flips it to true (needs Terraform >= 1.7 for import for_each).
# Removing the owner does not restore the local target: set nat_local_route_target =
# "local" and apply first, then drop the owner.
variable "adopt_nat_local_routes" {
  type    = bool
  default = false
}

# "firewall" replaces the adopted local route target with the AZ firewall endpoint;
# "local" asks the provider to ReplaceRoute back to LocalTarget (rollback path).
variable "nat_local_route_target" {
  type    = string
  default = "firewall"
  validation {
    condition     = contains(["firewall", "local"], var.nat_local_route_target)
    error_message = "nat_local_route_target must be firewall or local."
  }
}

locals {
  az          = "${var.region}a"
  tags        = { Name = var.name, Purpose = "disposable-egress-validation", Session = "cc2a2d8a82cc41ab84e1420f14da2493" }
  ssm_domains = ["ssm.${var.region}.amazonaws.com", "ssmmessages.${var.region}.amazonaws.com", "ec2messages.${var.region}.amazonaws.com"]
}

resource "aws_vpc" "validation" {
  cidr_block           = "10.201.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = local.tags
}

resource "aws_internet_gateway" "validation" {
  vpc_id = aws_vpc.validation.id
  tags   = local.tags
}

resource "aws_subnet" "cluster" {
  vpc_id            = aws_vpc.validation.id
  availability_zone = local.az
  cidr_block        = "10.201.0.0/20"
  tags              = local.tags
}

resource "aws_route_table" "cluster" {
  vpc_id = aws_vpc.validation.id
  tags   = local.tags
}

resource "aws_route_table_association" "cluster" {
  subnet_id      = aws_subnet.cluster.id
  route_table_id = aws_route_table.cluster.id
}

module "network" {
  source   = "../.."
  name     = var.name
  vpc_id   = aws_vpc.validation.id
  vpc_cidr = aws_vpc.validation.cidr_block
  # Disposable fixture: teardown must not need a separate unprotect apply.
  change_protection = false
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
  firewall_subnet_cidrs = { (local.az) = "10.201.240.0/28" }
  nat_subnet_cidrs      = { (local.az) = "10.201.56.0/24" }
  attachments = {
    workers = { policy_key = "workers", subnets_by_az = { (local.az) = { ipv4_cidr = "10.201.64.0/24" } } }
  }
  cluster_policy_key = "cluster"
  policies = {
    cluster = {
      domain_allow = {
        probe = { domains = concat(["example.com", "*.example.org"], local.ssm_domains, tolist(var.extra_https_domains)), protocol = "https" }
        plain = { domains = ["example.net"], protocol = "http" }
      }
      network_allow = var.allow_raw_ip ? {
        cloudflare_probe = { destination_ipv4_cidrs = ["1.1.1.1/32"], protocol = "tcp", destination_ports = [443], reason = "Disposable fixture raw IP exception probe" }
      } : {}
    }
    workers = { domain_allow = { probe = { domains = concat(["example.com"], local.ssm_domains), protocol = "https" } }, network_allow = {} }
  }
  reserved_subnet_cidrs = ["10.201.48.0/24"]
  depends_on            = [aws_route_table_association.cluster]
}

import {
  for_each = var.adopt_nat_local_routes ? module.network.nat_route_table_ids : {}
  to       = aws_route.nat_local[each.key]
  id       = "${each.value}_${aws_vpc.validation.cidr_block}"
}

resource "aws_route" "nat_local" {
  for_each               = var.adopt_nat_local_routes ? module.network.nat_route_table_ids : {}
  route_table_id         = each.value
  destination_cidr_block = aws_vpc.validation.cidr_block
  gateway_id             = var.nat_local_route_target == "local" ? "local" : null
  vpc_endpoint_id        = var.nat_local_route_target == "firewall" ? module.network.firewall_endpoint_ids[each.key] : null
}

output "nat_route_table_ids" { value = module.network.nat_route_table_ids }
output "nat_local_routes" { value = { for az, route in aws_route.nat_local : az => { id = route.id, gateway_id = route.gateway_id, vpc_endpoint_id = route.vpc_endpoint_id, origin = route.origin, state = route.state } } }

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.validation.id
  availability_zone       = local.az
  cidr_block              = "10.201.48.0/24"
  map_public_ip_on_launch = true
  tags                    = local.tags
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.validation.id
  tags   = local.tags
}

resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.validation.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
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

resource "aws_instance" "probe" {
  for_each                    = { cluster = module.network.cluster_subnet_ids[0], workers = module.network.attachments.workers.subnets_by_az[local.az].subnet_id }
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = "t3.micro"
  subnet_id                   = each.value
  vpc_security_group_ids      = [aws_security_group.probe.id]
  iam_instance_profile        = aws_iam_instance_profile.probe.name
  associate_public_ip_address = false
  tags                        = merge(local.tags, { Name = "${var.name}-${each.key}" })
  depends_on                  = [aws_iam_role_policy_attachment.ssm]
}

output "probe_instance_ids" { value = { for key, probe in aws_instance.probe : key => probe.id } }

output "egress_firewall" { value = module.network.attachments }
output "nat_public_ips" { value = module.network.nat_public_ips }
output "firewall_endpoint_ids" { value = module.network.firewall_endpoint_ids }
output "alert_log_group" { value = module.network.alert_log_group }
output "flow_log_group" { value = module.network.flow_log_group }

resource "aws_vpc" "origin" {
  cidr_block           = "10.203.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.name}-origin" })
}

resource "aws_internet_gateway" "origin" {
  vpc_id = aws_vpc.origin.id
  tags   = local.tags
}

resource "aws_subnet" "origin" {
  vpc_id                  = aws_vpc.origin.id
  availability_zone       = local.az
  cidr_block              = "10.203.0.0/24"
  map_public_ip_on_launch = true
  tags                    = local.tags
}

resource "aws_route_table" "origin" {
  vpc_id = aws_vpc.origin.id
  tags   = local.tags
}

resource "aws_route" "origin" {
  route_table_id         = aws_route_table.origin.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.origin.id
}

resource "aws_route_table_association" "origin" {
  subnet_id      = aws_subnet.origin.id
  route_table_id = aws_route_table.origin.id
}

resource "aws_security_group" "origin" {
  name   = "${var.name}-origin"
  vpc_id = aws_vpc.origin.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [for address in module.network.nat_public_ips : "${address}/32"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_instance" "origin" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.origin.id
  vpc_security_group_ids      = [aws_security_group.origin.id]
  iam_instance_profile        = aws_iam_instance_profile.probe.name
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data                   = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /opt/egfw-origin.key -out /opt/egfw-origin.crt -days 2 -subj /CN=example.com
    cat > /opt/egfw-origin.py <<'PY'
    import http.server
    import ssl

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("/opt/egfw-origin.crt", "/opt/egfw-origin.key")

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def setup(self):
            self.request = context.wrap_socket(self.request, server_side=True)
            super().setup()

        def do_GET(self):
            body = f"remote={self.client_address[0]} path={self.path}\\n".encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    server.serve_forever()
    PY
    cat > /etc/systemd/system/egfw-origin.service <<'SERVICE'
    [Unit]
    Description=Disposable egress firewall TLS origin
    After=network-online.target
    [Service]
    ExecStart=/usr/bin/python3 /opt/egfw-origin.py
    Restart=always
    [Install]
    WantedBy=multi-user.target
    SERVICE
    systemctl daemon-reload
    systemctl enable --now egfw-origin.service
  SCRIPT
  tags                        = merge(local.tags, { Name = "${var.name}-origin" })
  depends_on                  = [aws_route_table_association.origin, aws_iam_role_policy_attachment.ssm]
}

output "origin_public_ip" { value = aws_instance.origin.public_ip }

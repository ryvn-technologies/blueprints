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

variable "descriptor_file" {
  type = string
}

locals {
  az         = "${var.region}a"
  descriptor = jsondecode(file(var.descriptor_file)).workers
  subnet     = try(local.descriptor.subnets_by_az[local.az], null)
  tags = {
    Name    = "${var.name}-separate-consumer"
    Purpose = "disposable-egress-validation"
    Session = "cbc097828e5240688de052db9547e10f"
  }
}

resource "terraform_data" "contract" {
  input = local.descriptor
  lifecycle {
    precondition {
      condition     = try(local.descriptor.schema_version == 1 && local.descriptor.provider == "aws" && local.descriptor.policy_key == "workers" && local.subnet != null, false)
      error_message = "Consumer requires a version 1 AWS workers descriptor covering the requested availability zone."
    }
  }
}

data "aws_subnet" "attachment" {
  id = local.subnet.subnet_id
}

data "aws_route_table" "attachment" {
  route_table_id = local.subnet.route_table_id
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_security_group" "probe" {
  filter {
    name   = "group-name"
    values = ["${var.name}-probe"]
  }
  vpc_id = local.descriptor.vpc_id
}

data "aws_iam_instance_profile" "probe" {
  name = "${var.name}-probe"
}

resource "aws_instance" "consumer" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnet.attachment.id
  vpc_security_group_ids      = [data.aws_security_group.probe.id]
  iam_instance_profile        = data.aws_iam_instance_profile.probe.name
  associate_public_ip_address = false
  tags                        = local.tags

  lifecycle {
    precondition {
      condition     = data.aws_subnet.attachment.vpc_id == local.descriptor.vpc_id && data.aws_subnet.attachment.availability_zone == local.az && data.aws_subnet.attachment.cidr_block == local.subnet.ipv4_cidr && data.aws_route_table.attachment.vpc_id == local.descriptor.vpc_id
      error_message = "Descriptor subnet, route table, CIDR and VPC must match the live AWS attachment."
    }
  }
  depends_on = [terraform_data.contract]
}

output "consumer_instance_id" { value = aws_instance.consumer.id }

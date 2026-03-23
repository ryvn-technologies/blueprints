data "aws_vpc" "selected" {
  id = var.vpc_id
}

locals {
  private_subnet_ids  = split(",", var.private_subnet_ids)
  allowed_cidr_blocks = distinct(concat([data.aws_vpc.selected.cidr_block], var.allowed_cidr_blocks))
}

resource "aws_elasticache_subnet_group" "this" {
  name        = "${var.installation_name}-cache"
  description = "Subnet group for ${var.installation_name} ${var.engine}"
  subnet_ids  = local.private_subnet_ids

  tags = merge(var.tags, {
    Name = "${var.installation_name}-cache-subnet-group"
  })
}

resource "aws_security_group" "cache" {
  name_prefix = "${var.installation_name}-cache-"
  description = "Security group for ${var.installation_name} ${var.engine}"
  vpc_id      = var.vpc_id

  ingress {
    description = "${var.engine} access from allowed CIDR blocks"
    from_port   = var.port
    to_port     = var.port
    protocol    = "tcp"
    cidr_blocks = local.allowed_cidr_blocks
  }

  egress {
    description = "Allow outbound traffic within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  tags = merge(var.tags, {
    Name = "${var.installation_name}-cache-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

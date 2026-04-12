data "aws_vpc" "selected" {
  id = var.vpc_id
}

locals {
  private_subnet_ids  = split(",", var.private_subnet_ids)
  allowed_cidr_blocks = distinct(concat([data.aws_vpc.selected.cidr_block], var.allowed_cidr_blocks))
}

resource "aws_elasticache_subnet_group" "this" {
  name        = "${local.name}-cache"
  description = "Subnet group for ${local.name} ${var.engine}"
  subnet_ids  = local.private_subnet_ids

  tags = merge(local.all_tags, {
    Name = "${local.name}-cache-subnet-group"
  })
}

resource "aws_security_group" "cache" {
  name_prefix = "${local.name}-cache-"
  description = "Security group for ${local.name} ${var.engine}"
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

  tags = merge(local.all_tags, {
    Name = "${local.name}-cache-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

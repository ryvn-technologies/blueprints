data "aws_vpc" "selected" {
  id = var.vpc_id
}

locals {
  allowed_cidr_blocks = var.publicly_accessible ? (
    length(var.allowed_cidr_blocks) > 0
    ? distinct(concat([data.aws_vpc.selected.cidr_block], var.allowed_cidr_blocks))
    : ["0.0.0.0/0"]
  ) : distinct(concat([data.aws_vpc.selected.cidr_block], var.allowed_cidr_blocks))
}

resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-rds-"
  description = "Security group for ${local.name} PostgreSQL"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL access"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = local.allowed_cidr_blocks
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.all_tags, {
    Name = "${local.name}-rds-sg"
  })
}

resource "aws_db_subnet_group" "this" {
  name_prefix = "${local.name}-"
  subnet_ids  = split(",", var.subnet_ids)
  description = "Subnet group for ${local.name} PostgreSQL"

  tags = merge(local.all_tags, {
    Name = "${local.name}-subnet-group"
  })
}

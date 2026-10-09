terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"

  backend "kubernetes" {}
}

provider "aws" {
  region = var.aws_region
}

locals {
  all_tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment
  })

  policy_name = substr("${var.name_prefix}-cloud-metrics-reader", 0, 128)
}
# Distributed to BYOC hubs as a public module (github.com/ryvn-technologies/blueprints).

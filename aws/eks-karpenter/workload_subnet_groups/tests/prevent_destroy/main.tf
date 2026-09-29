# Offline harness for tests/prevent_destroy.sh: the real module against a
# provider that never talks to AWS. Only the terraform_data bookkeeping is
# applied (-target); aws_* resources stay unplanned.
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.28.0, != 6.57.0, < 7.0.0" }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "offline"
  secret_key                  = "offline"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

variable "groups" {
  type = list(object({
    name               = string
    ipv4_prefix_length = number
    availability_zones = list(string)
    retired            = optional(bool, false)
  }))
}

module "groups" {
  source   = "../.."
  name     = "offline"
  vpc_id   = "vpc-offline"
  vpc_cidr = "10.0.0.0/16"
  azs      = ["us-east-1a", "us-east-1b"]
  groups   = var.groups
}

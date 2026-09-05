terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.57.0 corrupts concurrent AWS API requests, cross-wiring bodies between
      # service clients (EC2 receiving sts:GetCallerIdentity, spliced ARNs, 302s
      # from STS). Fixed upstream in 6.57.1, which was pulled and republished the
      # same day specifically to fix this ("Fixes api error UnknownError:
      # UnknownError introduced in release 6.57.0"), so only that one release is
      # excluded:
      # https://github.com/hashicorp/terraform-provider-aws/blob/main/CHANGELOG.md
      version = ">= 6.28.0, != 6.57.0, < 7.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.4.0"
    }
  }
}

provider "aws" {
  region = var.region

  # The Ryvn control plane supplies assume_role_arn (RyvnAccessRole). Operators
  # applying directly omit it, and the provider runs on the ambient identity.
  dynamic "assume_role" {
    for_each = var.assume_role_arn != null ? [1] : []
    content {
      role_arn     = var.assume_role_arn
      session_name = "terraform"
    }
  }
}

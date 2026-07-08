terraform {
  # 1.9+ enables cross-variable input validation (see variables.tf).
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.51.0"
    }
  }

  backend "kubernetes" {}
}

provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_cloudfront_cache_policy" "this" {
  count = local.use_managed_cache_policy ? 1 : 0

  provider = aws.us_east_1
  name     = local.cache_policy_name
}

data "aws_cloudfront_origin_request_policy" "this" {
  count = local.use_managed_origin_request_policy ? 1 : 0

  provider = aws.us_east_1
  name     = local.origin_request_policy_name
}

data "aws_cloudfront_response_headers_policy" "this" {
  count = local.use_managed_response_headers_policy ? 1 : 0

  provider = aws.us_east_1
  name     = trimspace(var.response_headers_policy_name)
}

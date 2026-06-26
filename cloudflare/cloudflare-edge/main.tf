terraform {
  # 1.9+ enables cross-variable input validation (see variables.tf).
  required_version = ">= 1.9.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.20"
    }
  }

  backend "kubernetes" {}
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "cloudflare_ip_ranges" "this" {}

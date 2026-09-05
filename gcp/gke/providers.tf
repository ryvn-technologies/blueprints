terraform {
  # Ryvn's executor fetches this module with `terraform init -from-module`,
  # which does not carry .terraform.lock.hcl along, and customers consume it as
  # a child module where the lock file never applies. These constraints are the
  # only pin that reaches production, so each provider is held to one minor
  # (Google's root-module guidance) and bumped deliberately.
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.46.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.46.0"
    }
    # Required by the upstream GKE module; pinned here so every root that wraps
    # this module resolves the same versions.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

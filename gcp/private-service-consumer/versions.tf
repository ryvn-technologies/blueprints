terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.46"
    }
    # Required by the PSC endpoint module; held to the same versions as google.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.46"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.subnetwork_region
}

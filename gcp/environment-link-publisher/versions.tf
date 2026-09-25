terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.46"
    }
  }

  backend "kubernetes" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

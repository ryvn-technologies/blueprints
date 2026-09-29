terraform {
  # Actions wait for their dependencies only from 1.16.
  required_version = ">= 1.16.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.57.0 cross-wires concurrent AWS API requests; 6.57.1 fixes it.
      version = ">= 6.15.0, != 6.57.0, < 7.0.0"
    }
  }
}

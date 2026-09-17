terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
    }
  }
}

variable "iam_database_authentication_enabled" {
  type    = bool
  default = true
}

resource "random_password" "database" {
  length = 24
}

module "postgres" {
  source = "../../.."

  project_id                          = "test-project"
  name_prefix                         = "postgres"
  environment                         = "test"
  private_network                     = "projects/test-project/global/networks/default"
  database_username                   = "bootstrap"
  database_password                   = random_password.database.result
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
}

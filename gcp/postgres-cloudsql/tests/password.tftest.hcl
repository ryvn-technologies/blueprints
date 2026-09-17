mock_provider "google" {}
mock_provider "random" {}

variables {
  project_id                          = "test-project"
  name_prefix                         = "postgres"
  environment                         = "test"
  private_network                     = "projects/test-project/global/networks/default"
  iam_database_authentication_enabled = true
  iam_database_users = {
    app = { email = "app@test-project.iam.gserviceaccount.com", type = "CLOUD_IAM_SERVICE_ACCOUNT" }
  }
}

run "omits_password_when_iam_is_enabled" {
  command = apply

  assert {
    condition     = var.database_password == null && google_sql_database_instance.this.root_password == null && length(google_sql_user.application) == 0
    error_message = "An omitted password must leave the postgres password unset and create no password application user."
  }

  assert {
    condition     = output.username == null && output.password == null && output.connection_string == null
    error_message = "Password credential outputs must be null when no password is supplied."
  }

  assert {
    condition     = output.iam_database_users["app"].username == "app@test-project.iam" && google_sql_user.iam["app"].password == null
    error_message = "Omitting the password must preserve IAM account registration and its connection metadata."
  }
}

run "rejects_custom_username_without_password" {
  command = plan
  variables {
    database_password = null
    database_username = "bootstrap"
  }
  expect_failures = [google_sql_database_instance.this]
}

run "rejects_missing_password_without_iam" {
  command = plan
  variables {
    iam_database_authentication_enabled = false
    iam_database_users                  = {}
  }
  expect_failures = [google_sql_database_instance.this]
}

run "rejects_empty_password" {
  command = plan
  variables {
    database_password = ""
  }
  expect_failures = [var.database_password]
}

run "adds_password_accounts_to_an_iam_instance" {
  command = apply
  variables {
    database_password = "bootstrap-password"
    database_username = "bootstrap"
  }

  assert {
    condition     = google_sql_database_instance.this.root_password == var.database_password && google_sql_user.application[0].password == var.database_password && output.username == "bootstrap" && output.password == var.database_password && output.connection_string != null && length(google_sql_user.iam) == 1
    error_message = "Supplying a password later must configure both password accounts while retaining IAM users."
  }
}

run "resetting_username_and_removing_password_removes_the_application_user" {
  command = plan
  variables {
    database_username = "postgres"
  }

  assert {
    condition     = google_sql_database_instance.this.root_password == null && length(google_sql_user.application) == 0 && output.username == null && output.password == null && output.connection_string == null && length(google_sql_user.iam) == 1
    error_message = "Resetting the username and removing the password must plan removal of the password application user and credentials while retaining IAM users."
  }
}

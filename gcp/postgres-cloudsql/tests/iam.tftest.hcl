mock_provider "google" {
  mock_resource "google_tags_location_tag_binding" {
    defaults = {
      id = "tagBindings/test"
    }
  }

  mock_resource "google_sql_database_instance" {
    defaults = {
      connection_name    = "test-project:us-central1:postgres-test"
      private_ip_address = "10.0.0.2"
      public_ip_address  = "192.0.2.1"
    }
  }
}

mock_provider "random" {
  mock_resource "random_id" {
    defaults = { hex = "test" }
  }
}

mock_provider "time" {}

variables {
  project_id        = "test-project"
  name_prefix       = "postgres"
  environment       = "test"
  database_password = "bootstrap-password"
  private_network   = "projects/test-project/global/networks/default"
}

run "managed_tag_waits_for_propagation" {
  command = plan

  variables {
    managed_tag_value = "tagValues/123"
  }

  assert {
    condition     = length(time_sleep.managed_tag_propagation) == 1 && time_sleep.managed_tag_propagation[0].create_duration == "90s"
    error_message = "A managed tag must create the default propagation wait."
  }
}

run "no_managed_tag_skips_wait" {
  command = plan

  assert {
    condition     = length(time_sleep.managed_tag_propagation) == 0
    error_message = "Without a managed tag, no propagation wait should be created."
  }
}

run "password_authentication_is_the_default" {
  command = apply

  assert {
    condition     = length(google_sql_database_instance.this.settings[0].database_flags) == 0 && length(google_sql_user.iam) == 0 && output.iam_database_users == {}
    error_message = "Existing callers must retain the original flags and create no IAM users."
  }

  assert {
    condition     = google_sql_database_instance.this.root_password == var.database_password && output.username == "postgres" && output.password == var.database_password && output.connection_string == "postgresql://postgres:bootstrap-password@10.0.0.2:5432/postgres?sslmode=require"
    error_message = "The default administrator and password connection outputs must remain unchanged."
  }
}

run "enables_iam_without_requiring_managed_users" {
  command = apply
  variables {
    iam_database_authentication_enabled = true
  }

  assert {
    condition     = { for flag in google_sql_database_instance.this.settings[0].database_flags : flag.name => flag.value } == { "cloudsql.iam_authentication" = "on" } && length(google_sql_user.iam) == 0
    error_message = "Callers must be able to enable IAM while managing database accounts elsewhere."
  }
}

run "registers_identities_and_preserves_password_users_and_cron" {
  command = apply
  variables {
    iam_database_authentication_enabled = true
    database_name                       = "app"
    database_username                   = "bootstrap"
    managed_tag_value                   = "tagValues/123456789012"
    iam_database_users = {
      app      = { email = "app@test-project.iam.gserviceaccount.com", type = "CLOUD_IAM_SERVICE_ACCOUNT" }
      operator = { email = "operator@example.com", type = "CLOUD_IAM_USER" }
      readers  = { email = "readers@example.com", type = "CLOUD_IAM_GROUP" }
      compute  = { email = "123456789-compute@developer.gserviceaccount.com", type = "CLOUD_IAM_SERVICE_ACCOUNT" }
    }
  }

  assert {
    condition = { for flag in google_sql_database_instance.this.settings[0].database_flags : flag.name => flag.value } == {
      "cloudsql.iam_authentication" = "on"
      "cloudsql.enable_pg_cron"     = "on"
      "cron.database_name"          = "postgres"
    }
    error_message = "Enabling IAM must preserve the existing pg_cron settings."
  }

  assert {
    condition = { for key, user in google_sql_user.iam : key => { username = user.name, type = user.type } } == {
      app      = { username = "app@test-project.iam", type = "CLOUD_IAM_SERVICE_ACCOUNT" }
      operator = { username = "operator@example.com", type = "CLOUD_IAM_USER" }
      readers  = { username = "readers@example.com", type = "CLOUD_IAM_GROUP" }
      compute  = { username = "123456789-compute@developer", type = "CLOUD_IAM_SERVICE_ACCOUNT" }
    }
    error_message = "Register each principal under its stable key, converting only service-account email suffixes."
  }

  assert {
    condition     = alltrue([for user in google_sql_user.iam : user.password == null && user.project == var.project_id && user.instance == google_sql_database_instance.this.name])
    error_message = "IAM accounts must be passwordless and registered on this project's instance."
  }

  assert {
    condition     = google_sql_user.application[0].name == "bootstrap" && google_sql_user.application[0].password == var.database_password && google_sql_database_instance.this.root_password == var.database_password && output.username == "bootstrap" && output.password == var.database_password && output.connection_string == "postgresql://bootstrap:bootstrap-password@10.0.0.2:5432/app?sslmode=require"
    error_message = "IAM accounts must coexist with the existing password administrator and application account."
  }

  assert {
    condition = output.iam_database_users == {
      app      = { email = "app@test-project.iam.gserviceaccount.com", username = "app@test-project.iam", type = "CLOUD_IAM_SERVICE_ACCOUNT", member = "serviceAccount:app@test-project.iam.gserviceaccount.com" }
      operator = { email = "operator@example.com", username = "operator@example.com", type = "CLOUD_IAM_USER", member = "user:operator@example.com" }
      readers  = { email = "readers@example.com", username = "readers@example.com", type = "CLOUD_IAM_GROUP", member = "group:readers@example.com" }
      compute  = { email = "123456789-compute@developer.gserviceaccount.com", username = "123456789-compute@developer", type = "CLOUD_IAM_SERVICE_ACCOUNT", member = "serviceAccount:123456789-compute@developer.gserviceaccount.com" }
    }
    error_message = "Outputs must distinguish SQL usernames from the full Google IAM identities."
  }

  assert {
    condition     = output.project_id == "test-project" && output.instance_resource_name == "projects/test-project/instances/postgres-test" && output.connection_name == "test-project:us-central1:postgres-test"
    error_message = "Export both the IAM resource name and the distinct proxy connection name."
  }
}

run "rejects_users_when_iam_is_disabled" {
  command = plan
  variables {
    iam_database_users = {
      app = { email = "app@test-project.iam.gserviceaccount.com", type = "CLOUD_IAM_SERVICE_ACCOUNT" }
    }
  }
  expect_failures = [google_sql_database_instance.this]
}

run "rejects_duplicate_database_names_across_identity_types" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_database_users = {
      app   = { email = "app@test-project.iam.gserviceaccount.com", type = "CLOUD_IAM_SERVICE_ACCOUNT" }
      human = { email = "app@test-project.iam", type = "CLOUD_IAM_USER" }
    }
  }
  expect_failures = [google_sql_database_instance.this]
}

run "rejects_collision_with_builtin_application_user" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    database_username                   = " app@test-project.iam "
    iam_database_users = {
      app = { email = "app@test-project.iam.gserviceaccount.com", type = "CLOUD_IAM_SERVICE_ACCOUNT" }
    }
  }
  expect_failures = [google_sql_database_instance.this]
}

run "rejects_cloud_managed_group_member_types" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_database_users = {
      app = { email = "app@test-project.iam.gserviceaccount.com", type = "CLOUD_IAM_GROUP_SERVICE_ACCOUNT" }
    }
  }
  expect_failures = [var.iam_database_users]
}

run "rejects_uppercase_names" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_database_users = {
      operator = { email = "Operator@example.com", type = "CLOUD_IAM_USER" }
    }
  }
  expect_failures = [var.iam_database_users]
}

run "rejects_malformed_emails" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_database_users = {
      operator = { email = "operator", type = "CLOUD_IAM_USER" }
    }
  }
  expect_failures = [var.iam_database_users]
}

run "rejects_truncated_service_account_emails" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_database_users = {
      app = { email = "app@test-project.iam", type = "CLOUD_IAM_SERVICE_ACCOUNT" }
    }
  }
  expect_failures = [var.iam_database_users]
}

run "rejects_service_accounts_with_human_type" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_database_users = {
      app = { email = "app@test-project.iam.gserviceaccount.com", type = "CLOUD_IAM_USER" }
    }
  }
  expect_failures = [var.iam_database_users]
}

run "rejects_oversized_database_names" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_database_users = {
      operator = { email = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz@example.com", type = "CLOUD_IAM_USER" }
    }
  }
  expect_failures = [var.iam_database_users]
}

run "rejects_null_user_entries" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_database_users                  = { app = null }
  }
  expect_failures = [var.iam_database_users]
}

run "rejects_null_email" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_database_users = {
      operator = { email = null, type = "CLOUD_IAM_USER" }
    }
  }
  expect_failures = [var.iam_database_users]
}

run "rejects_null_type" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_database_users = {
      operator = { email = "operator@example.com", type = null }
    }
  }
  expect_failures = [var.iam_database_users]
}

run "removes_iam_and_retains_password_access_and_cron" {
  command = apply
  variables {
    database_name     = "app"
    database_username = "bootstrap"
  }

  assert {
    condition = { for flag in google_sql_database_instance.this.settings[0].database_flags : flag.name => flag.value } == {
      "cloudsql.enable_pg_cron" = "on"
      "cron.database_name"      = "postgres"
    }
    error_message = "Removing IAM must retain pg_cron configuration."
  }

  assert {
    condition     = length(google_sql_user.iam) == 0 && output.iam_database_users == {} && google_sql_user.application[0].password == var.database_password
    error_message = "Removing IAM users and disabling IAM must preserve password access."
  }
}

mock_provider "google" {
  mock_data "google_client_openid_userinfo" {
    defaults = {
      email = "terraform@example.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      name   = "projects/test-project/serviceAccounts/gke-test-sa@test-project.iam.gserviceaccount.com"
      email  = "gke-test-sa@test-project.iam.gserviceaccount.com"
      member = "serviceAccount:gke-test-sa@test-project.iam.gserviceaccount.com"
    }
  }
}

mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "random" {}

variables {
  environment          = "test-env"
  project_id           = "test-project"
  region               = "us-central1"
  zones                = ["us-central1-a"]
  public_root_domain   = "test.example.com"
  internal_root_domain = "test.internal"
}

run "defaults_when_nothing_is_supplied" {
  command = plan

  assert {
    condition     = length(google_project_iam_custom_role.ryvn_agent_role) == 1 && contains(google_project_iam_custom_role.ryvn_agent_role[0].permissions, "resourcemanager.projects.get")
    error_message = "The default custom role should be created with the default permissions."
  }

  assert {
    condition     = length(google_project_iam_member.ryvn_agent_cloudsql_role_binding) == 1
    error_message = "The tag-scoped Cloud SQL grant should be present by default."
  }

  assert {
    condition     = length(google_project_iam_member.ryvn_agent_bindings) == 0 && length(google_project_iam_custom_role.ryvn_agent_binding_role) == 0
    error_message = "No extra bindings or roles should exist without configuration."
  }
}

run "predefined_role_binding_with_condition" {
  command = plan

  variables {
    terraform_executor_policies = {
      bindings = [{
        name = "kms"
        role = "roles/cloudkms.admin"
        condition = {
          title      = "Ryvn key rings only"
          expression = "resource.name.startsWith(\"projects/test-project/locations/us-central1/keyRings/test-env-\")"
        }
      }]
    }
  }

  assert {
    condition     = google_project_iam_member.ryvn_agent_bindings["kms"].role == "roles/cloudkms.admin"
    error_message = "The predefined role should be bound as given."
  }

  assert {
    condition     = length(google_project_iam_member.ryvn_agent_bindings["kms"].condition) == 1 && google_project_iam_member.ryvn_agent_bindings["kms"].condition[0].title == "Ryvn key rings only"
    error_message = "The IAM condition should be attached to the binding."
  }

  assert {
    condition     = length(google_project_iam_custom_role.ryvn_agent_binding_role) == 0
    error_message = "A predefined role binding should not create a custom role."
  }
}

run "custom_permissions_create_a_role_per_binding" {
  command = plan

  variables {
    terraform_executor_policies = {
      bindings = [{
        name        = "kms-keys"
        permissions = ["cloudkms.keyRings.create", "cloudkms.cryptoKeys.create"]
      }]
    }
  }

  assert {
    condition     = google_project_iam_custom_role.ryvn_agent_binding_role["kms-keys"].role_id == "ryvn_agent_test_env_kms_keys"
    error_message = "The custom role id should be derived from the environment and binding name."
  }

  assert {
    condition     = length(google_project_iam_member.ryvn_agent_bindings["kms-keys"].condition) == 0
    error_message = "A binding without a condition should be unconditional."
  }
}

run "any_override_replaces_the_default_role_set" {
  command = plan

  variables {
    terraform_executor_policies = {
      bindings = [{
        name = "kms"
        role = "roles/cloudkms.admin"
      }]
    }
  }

  assert {
    condition     = length(google_project_iam_custom_role.ryvn_agent_role) == 0 && length(google_project_iam_binding.ryvn_agent_role_binding) == 0
    error_message = "An override should drop the default custom role and its binding."
  }

  assert {
    condition     = length(google_project_iam_custom_role.ryvn_agent_cloudsql_role) == 0 && length(google_project_iam_member.ryvn_agent_cloudsql_role_binding) == 0
    error_message = "An override should drop the tag-scoped Cloud SQL grant."
  }

  assert {
    condition     = google_tags_tag_key.cloudsql_managed.short_name == "ryvn-managed-test-env" && google_tags_tag_value.cloudsql_managed.short_name == "true"
    error_message = "The Cloud SQL tag should survive an override so instances stay taggable and existing tag bindings are not destroyed."
  }
}

run "roles_alone_replace_the_defaults" {
  command = plan

  variables {
    terraform_executor_policies = {
      roles = ["roles/cloudkms.admin"]
    }
  }

  assert {
    condition     = length(google_project_iam_custom_role.ryvn_agent_role) == 0 && google_project_iam_member.ryvn_agent_roles["roles/cloudkms.admin"].role == "roles/cloudkms.admin"
    error_message = "Predefined roles should be bound without the default custom role."
  }
}

run "permissions_build_the_custom_role_and_compose_with_roles" {
  command = plan

  variables {
    terraform_executor_policies = {
      roles       = ["roles/cloudkms.admin"]
      permissions = ["compute.disks.get"]
    }
  }

  assert {
    condition     = google_project_iam_custom_role.ryvn_agent_role[0].permissions == toset(["compute.disks.get"]) && length(google_project_iam_binding.ryvn_agent_role_binding) == 1
    error_message = "Supplied permissions should become the custom role, replacing the defaults."
  }

  assert {
    condition     = length(google_project_iam_member.ryvn_agent_roles) == 1
    error_message = "Roles and permissions should be allowed together."
  }
}

run "binding_needs_exactly_one_of_role_or_permissions" {
  command = plan

  variables {
    terraform_executor_policies = {
      bindings = [{
        name        = "both"
        role        = "roles/cloudkms.admin"
        permissions = ["cloudkms.keyRings.create"]
      }]
    }
  }

  expect_failures = [var.terraform_executor_policies]
}

run "binding_names_must_be_unique" {
  command = plan

  variables {
    terraform_executor_policies = {
      bindings = [
        { name = "kms", role = "roles/cloudkms.admin" },
        { name = "kms", role = "roles/cloudkms.viewer" },
      ]
    }
  }

  expect_failures = [var.terraform_executor_policies]
}

run "binding_name_must_fit_the_role_id" {
  command = plan

  variables {
    terraform_executor_policies = {
      bindings = [{
        name = "this-name-is-too-long"
        role = "roles/cloudkms.admin"
      }]
    }
  }

  expect_failures = [var.terraform_executor_policies]
}

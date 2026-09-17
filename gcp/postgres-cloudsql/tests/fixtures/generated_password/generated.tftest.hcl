mock_provider "random" {}

# The child module configures its own Google provider. Override every Google
# resource to keep these caller-plan tests offline.
override_resource {
  target = module.postgres.google_sql_database_instance.this
}

override_resource {
  target = module.postgres.google_tags_location_tag_binding.managed
}

override_resource {
  target = module.postgres.google_sql_database.this
}

override_resource {
  target = module.postgres.google_sql_user.application
}

override_resource {
  target = module.postgres.google_sql_user.iam
}

run "plans_generated_password_with_iam" {
  command = plan
}

run "plans_generated_password_without_iam" {
  command = plan
  variables {
    iam_database_authentication_enabled = false
  }
}

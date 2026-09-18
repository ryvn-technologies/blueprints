locals {
  iam_member_prefixes = {
    CLOUD_IAM_USER            = "user"
    CLOUD_IAM_SERVICE_ACCOUNT = "serviceAccount"
    CLOUD_IAM_GROUP           = "group"
  }

  iam_database_users = {
    for key, user in var.iam_database_users : key => {
      email    = user.email
      type     = user.type
      username = user.type == "CLOUD_IAM_SERVICE_ACCOUNT" ? trimsuffix(user.email, ".gserviceaccount.com") : user.email
      member   = "${local.iam_member_prefixes[user.type]}:${user.email}"
    }
  }
}

# IAM identities already exist. This registers their database accounts; callers
# own the Google IAM bindings, workload associations, and SQL privileges.
resource "google_sql_user" "iam" {
  for_each = local.iam_database_users

  depends_on = [google_tags_location_tag_binding.managed, time_sleep.managed_tag_propagation]

  project  = var.project_id
  instance = google_sql_database_instance.this.name
  name     = each.value.username
  type     = each.value.type
}

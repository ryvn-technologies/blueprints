data "aws_partition" "current" {
  count = var.iam_database_authentication_enabled ? 1 : 0
}

data "aws_caller_identity" "current" {
  count = var.iam_database_authentication_enabled ? 1 : 0
}

locals {
  iam_database_users = var.iam_database_authentication_enabled ? {
    for kind, username in {
      master     = var.database_username
      read_only  = var.iam_read_only_username
      read_write = var.iam_read_write_username
    } : kind => username if username != null
  } : {}
}

# The workload identity module owns roles and Pod Identity associations. Each
# policy authorizes one database login; SQL grants determine its privileges.
resource "aws_iam_policy" "database_connect" {
  for_each = local.iam_database_users

  name_prefix = "${local.name}-${each.key}-"
  path        = "/ryvn/postgres/"
  description = "Connect to ${local.name} using the ${each.key} database login"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:${data.aws_partition.current[0].partition}:rds-db:${var.aws_region}:${data.aws_caller_identity.current[0].account_id}:dbuser:${aws_db_instance.this.resource_id}/${each.value}"
    }]
  })

  tags = local.all_tags

  lifecycle {
    precondition {
      condition     = length(distinct(values(local.iam_database_users))) == length(local.iam_database_users)
      error_message = "The master, read-only, and read-write IAM logins must be distinct."
    }
    precondition {
      condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]{0,62}$", each.value))
      error_message = "IAM database usernames must be 1-63 letters, digits or underscores, starting with a letter or underscore."
    }
  }
}

# On an existing instance, the resource's computed secret list can stay empty
# during the plan that enables managed passwords. Read metadata after the update.
data "aws_db_instance" "master_secret" {
  count = var.manage_master_user_password ? 1 : 0

  db_instance_identifier = aws_db_instance.this.identifier
  depends_on             = [aws_db_instance.this]
}

resource "aws_iam_policy" "master_secret_read" {
  count = var.manage_master_user_password ? 1 : 0

  name_prefix = "${local.name}-master-secret-"
  path        = "/ryvn/postgres/"
  description = "Read the master password for ${local.name}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = data.aws_db_instance.master_secret[0].master_user_secret[0].secret_arn
    }]
  })

  tags = local.all_tags
}

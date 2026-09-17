locals {
  # ElastiCache user names are capped at 40 characters. Keep the random suffix
  # and the role suffix; trim the installation name to fit.
  iam_user_prefix = "${trimsuffix(substr(var.installation_name, 0, 40 - length("-${random_id.suffix.hex}-admin")), "-")}-${random_id.suffix.hex}"

  iam_users = var.iam_authentication_enabled ? {
    admin = {
      user_name     = coalesce(var.iam_admin_username, "${local.iam_user_prefix}-admin")
      access_string = var.iam_admin_access_string
    }
    read_only = {
      user_name     = coalesce(var.iam_read_only_username, "${local.iam_user_prefix}-ro")
      access_string = var.iam_read_only_access_string
    }
    read_write = {
      user_name     = coalesce(var.iam_read_write_username, "${local.iam_user_prefix}-rw")
      access_string = var.iam_read_write_access_string
    }
  } : {}

  # Redis user groups must contain a user named "default"; Valkey groups
  # disable the default user automatically and reject passwordless users.
  manage_default_user = var.iam_authentication_enabled && var.engine == "redis"
}

# IAM users authenticate with SigV4 tokens; ElastiCache stores no secret for them.
# The user ID and user name must match for IAM authentication.
resource "aws_elasticache_user" "iam" {
  for_each = local.iam_users

  user_id       = each.value.user_name
  user_name     = each.value.user_name
  engine        = var.engine
  access_string = each.value.access_string

  authentication_mode {
    type = "iam"
  }

  tags = local.all_tags

  lifecycle {
    precondition {
      condition     = length(distinct([for user in local.iam_users : user.user_name])) == length(local.iam_users)
      error_message = "The admin, read-only, and read-write IAM usernames must be distinct."
    }
    precondition {
      condition     = can(regex("^[A-Za-z][A-Za-z0-9-]{0,39}$", each.value.user_name)) && each.value.user_name != "default"
      error_message = "IAM cache usernames must be 1-40 letters, digits or hyphens, start with a letter, and must not be \"default\"."
    }
    precondition {
      condition     = can(regex("(^|\\s)on(\\s|$)", each.value.access_string))
      error_message = "IAM access strings must include \"on\", otherwise the user cannot connect."
    }
  }
}

# Replaces the built-in "default" user (full access, no password) with a
# disabled one so only IAM identities can connect.
resource "aws_elasticache_user" "default" {
  count = local.manage_default_user ? 1 : 0

  user_id       = "${local.name}-default"
  user_name     = "default"
  engine        = var.engine
  access_string = "off -@all"

  authentication_mode {
    type = "no-password-required"
  }

  tags = local.all_tags
}

resource "aws_elasticache_user_group" "this" {
  count = var.iam_authentication_enabled ? 1 : 0

  user_group_id = local.name
  engine        = var.engine
  user_ids = concat(
    [for user in aws_elasticache_user.iam : user.user_id],
    [for user in aws_elasticache_user.default : user.user_id],
  )

  tags = local.all_tags
}

resource "aws_iam_policy" "cache_connect" {
  for_each = local.iam_users

  name_prefix = "${local.name}-${each.key}-"
  path        = "/ryvn/cache/"
  description = "Connect to ${local.name} using the ${each.key} cache login"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "elasticache:Connect"
      Resource = [
        aws_elasticache_replication_group.this.arn,
        aws_elasticache_user.iam[each.key].arn,
      ]
    }]
  })

  tags = local.all_tags
}

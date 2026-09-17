mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_resource "aws_elasticache_replication_group" {
    defaults = {
      arn                      = "arn:aws:elasticache:us-east-1:123456789012:replicationgroup:cache-test"
      primary_endpoint_address = "cache-test.example.cache.amazonaws.com"
      reader_endpoint_address  = "cache-test-ro.example.cache.amazonaws.com"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/ryvn/cache/cache-test" }
  }
}
mock_provider "random" {
  mock_resource "random_id" {
    defaults = { hex = "0a1b2c3d" }
  }
  mock_resource "random_password" {
    defaults = { result = "generated-auth-token-0123456789abcdef" }
  }
}

variables {
  installation_name  = "cache"
  environment        = "test"
  vpc_id             = "vpc-test"
  private_subnet_ids = "subnet-a,subnet-b"
}

run "auth_token_is_the_default" {
  command = apply
  assert {
    condition     = length(aws_elasticache_user.iam) == 0 && length(aws_elasticache_user.default) == 0 && length(aws_elasticache_user_group.this) == 0 && length(aws_iam_policy.cache_connect) == 0
    error_message = "Existing installations must keep AUTH-token authentication without creating RBAC users or IAM policies."
  }
  assert {
    condition     = aws_elasticache_replication_group.this.auth_token == random_password.auth_token[0].result && aws_elasticache_replication_group.this.user_group_ids == null
    error_message = "The generated AUTH token must still be applied and no user group attached."
  }
  assert {
    condition     = output.auth_token == random_password.auth_token[0].result && output.connection_url == "rediss://default:generated-auth-token-0123456789abcdef@cache-test.example.cache.amazonaws.com:6379"
    error_message = "Token outputs must remain compatible."
  }
  assert {
    condition     = output.admin_iam_policy_arn == "" && output.read_only_iam_policy_arn == "" && output.read_write_iam_policy_arn == "" && output.user_group_id == null && length(output.iam_users) == 0 && !output.iam_authentication_enabled
    error_message = "Disabled IAM must expose no policy ARNs or logins."
  }
}

run "iam_replaces_the_auth_token_with_rbac_users" {
  command = apply
  variables {
    iam_authentication_enabled = true
  }
  assert {
    condition     = aws_elasticache_replication_group.this.auth_token == null && length(random_password.auth_token) == 0 && output.auth_token == null
    error_message = "IAM authentication must not generate or apply a cluster AUTH token."
  }
  assert {
    condition     = output.connection_url == "rediss://cache-test.example.cache.amazonaws.com:6379"
    error_message = "The connection URL must not embed credentials when IAM is enabled."
  }
  assert {
    condition     = length(aws_elasticache_replication_group.this.user_group_ids) == 1 && contains(aws_elasticache_replication_group.this.user_group_ids, aws_elasticache_user_group.this[0].id) && aws_elasticache_user_group.this[0].user_group_id == "cache-0a1b2c3d" && output.user_group_id == aws_elasticache_user_group.this[0].id
    error_message = "The replication group must be attached to the module-managed user group."
  }
  assert {
    condition     = keys(aws_elasticache_user.iam) == ["admin", "read_only", "read_write"] && alltrue([for user in aws_elasticache_user.iam : user.authentication_mode[0].type == "iam" && user.user_id == user.user_name && user.engine == "redis"])
    error_message = "All IAM logins must use IAM authentication with matching user ID and name."
  }
  assert {
    condition     = output.iam_users.admin.user_name == "cache-0a1b2c3d-admin" && output.iam_users.read_only.user_name == "cache-0a1b2c3d-ro" && output.iam_users.read_write.user_name == "cache-0a1b2c3d-rw"
    error_message = "Default IAM usernames must derive from the cache name."
  }
  assert {
    condition     = aws_elasticache_user.iam["admin"].access_string == "on ~* &* +@all" && startswith(aws_elasticache_user.iam["read_only"].access_string, "on ~* &* -@all +@read") && startswith(aws_elasticache_user.iam["read_write"].access_string, "on ~* &* +@all -@admin")
    error_message = "Default access strings must grant full, read-only, and read-write privileges respectively."
  }
  assert {
    condition     = length(aws_elasticache_user.default) == 1 && aws_elasticache_user.default[0].user_name == "default" && aws_elasticache_user.default[0].access_string == "off -@all" && aws_elasticache_user.default[0].authentication_mode[0].type == "no-password-required"
    error_message = "Redis user groups must replace the built-in default user with a disabled one."
  }
  assert {
    condition     = toset(aws_elasticache_user_group.this[0].user_ids) == toset(concat([for user in aws_elasticache_user.iam : user.user_id], [aws_elasticache_user.default[0].user_id]))
    error_message = "The user group must contain every IAM login and the disabled default user."
  }
  assert {
    condition     = output.admin_iam_policy_arn != "" && output.read_only_iam_policy_arn != "" && output.read_write_iam_policy_arn != ""
    error_message = "Each login must expose a policy ARN for the workload identity module."
  }
}

run "separate_policies_authorize_only_their_cache_login" {
  command = apply
  variables {
    iam_authentication_enabled = true
  }
  assert {
    condition = alltrue([
      for kind, policy in aws_iam_policy.cache_connect :
      jsondecode(policy.policy).Statement[0].Action == "elasticache:Connect" &&
      jsondecode(policy.policy).Statement[0].Effect == "Allow" &&
      toset(jsondecode(policy.policy).Statement[0].Resource) == toset([aws_elasticache_replication_group.this.arn, aws_elasticache_user.iam[kind].arn])
    ])
    error_message = "Each policy must allow elasticache:Connect only on the replication group and its own user."
  }
  assert {
    condition     = alltrue([for policy in aws_iam_policy.cache_connect : policy.path == "/ryvn/cache/"])
    error_message = "Cache policies must share the /ryvn/cache/ path."
  }
}

run "valkey_user_groups_do_not_manage_a_default_user" {
  command = apply
  variables {
    iam_authentication_enabled = true
    engine                     = "valkey"
  }
  assert {
    condition     = length(aws_elasticache_user.default) == 0 && aws_elasticache_user_group.this[0].engine == "valkey" && alltrue([for user in aws_elasticache_user.iam : user.engine == "valkey"])
    error_message = "Valkey disables the default user automatically and rejects passwordless users, so none must be created."
  }
  assert {
    condition     = toset(aws_elasticache_user_group.this[0].user_ids) == toset([for user in aws_elasticache_user.iam : user.user_id])
    error_message = "Valkey user groups must contain only the IAM logins."
  }
}

run "custom_usernames_and_access_strings_are_applied" {
  command = apply
  variables {
    iam_authentication_enabled   = true
    iam_admin_username           = "cache-admin"
    iam_read_only_username       = "app-ro"
    iam_read_write_username      = "app-rw"
    iam_read_write_access_string = "on ~app:* +@all -@dangerous"
  }
  assert {
    condition     = output.iam_users.admin.user_name == "cache-admin" && output.iam_users.read_only.user_name == "app-ro" && output.iam_users.read_write.user_name == "app-rw"
    error_message = "Caller-provided usernames must be applied."
  }
  assert {
    condition     = aws_elasticache_user.iam["read_write"].access_string == "on ~app:* +@all -@dangerous"
    error_message = "Caller-provided access strings must be applied."
  }
}

run "default_usernames_fit_long_installation_names" {
  command = apply
  variables {
    installation_name          = "a-very-long-installation-name1"
    iam_authentication_enabled = true
  }
  assert {
    condition     = alltrue([for user in output.iam_users : length(user.user_name) <= 40 && endswith(user.user_name, "-0a1b2c3d-${split("-", user.user_name)[length(split("-", user.user_name)) - 1]}")])
    error_message = "Generated usernames must stay within 40 characters while keeping the random and role suffixes."
  }
  assert {
    condition     = output.iam_users.admin.user_name == "a-very-long-installation-0a1b2c3d-admin" && output.iam_users.read_only.user_name == "a-very-long-installation-0a1b2c3d-ro"
    error_message = "The installation name must be trimmed, not the suffixes."
  }
}

run "iam_requires_transit_encryption" {
  command = plan
  variables {
    iam_authentication_enabled = true
    transit_encryption_enabled = false
  }
  expect_failures = [aws_elasticache_replication_group.this]
}

run "iam_rejects_a_cluster_auth_token" {
  command = plan
  variables {
    iam_authentication_enabled = true
    auth_token                 = "caller-provided-token-0123456789"
  }
  expect_failures = [aws_elasticache_replication_group.this]
}

run "iam_requires_redis_7" {
  command = plan
  variables {
    iam_authentication_enabled = true
    engine_version             = "6.2"
  }
  expect_failures = [aws_elasticache_replication_group.this]
}

run "iam_usernames_must_be_distinct" {
  command = plan
  variables {
    iam_authentication_enabled = true
    iam_read_only_username     = "app"
    iam_read_write_username    = "app"
  }
  expect_failures = [aws_elasticache_user.iam]
}

run "iam_usernames_cannot_be_default" {
  command = plan
  variables {
    iam_authentication_enabled = true
    iam_admin_username         = "default"
  }
  expect_failures = [aws_elasticache_user.iam]
}

run "iam_access_strings_must_enable_the_user" {
  command = plan
  variables {
    iam_authentication_enabled  = true
    iam_read_only_access_string = "~* +@read"
  }
  expect_failures = [aws_elasticache_user.iam]
}

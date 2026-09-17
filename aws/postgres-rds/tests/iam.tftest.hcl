mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_db_instance" {
    defaults = {
      master_user_secret = [{
        kms_key_id    = "arn:aws:kms:us-east-1:123456789012:key/example"
        secret_arn    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-example"
        secret_status = "active"
      }]
    }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      resource_id = "db-ABCDEFGHIJKLMNOP"
      address     = "example.us-east-1.rds.amazonaws.com"
      master_user_secret = [{
        kms_key_id    = "arn:aws:kms:us-east-1:123456789012:key/example"
        secret_arn    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-example"
        secret_status = "active"
      }]
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/rds-monitoring" }
  }
}
mock_provider "random" {}

variables {
  name_prefix       = "postgres"
  environment       = "test"
  vpc_id            = "vpc-test"
  subnet_ids        = "subnet-a,subnet-b"
  database_username = "postgres"
  database_password = "bootstrap-password"
}

run "password_authentication_is_the_default" {
  command = apply
  variables {
    iam_read_only_username  = "app_ro"
    iam_read_write_username = "app_rw"
  }
  assert {
    condition     = !aws_db_instance.this.iam_database_authentication_enabled && length(aws_iam_policy.database_connect) == 0
    error_message = "Existing installations must keep password authentication without creating IAM grants."
  }
  assert {
    condition     = output.master_iam_policy_arn == "" && output.read_only_iam_policy_arn == "" && output.read_write_iam_policy_arn == "" && length(data.aws_caller_identity.current) == 0
    error_message = "Disabled IAM must expose no grant ARNs or require an additional identity lookup."
  }
  assert {
    condition     = !coalesce(aws_db_instance.this.manage_master_user_password, false) && output.password == var.database_password && output.connection_string != null && output.master_user_secret_arn == null
    error_message = "Password authentication must keep caller-provided credentials and leave Secrets Manager disabled."
  }
  assert {
    condition     = output.master_secret_read_policy_arn == "" && length(aws_iam_policy.master_secret_read) == 0 && length(data.aws_db_instance.master_secret) == 0
    error_message = "Caller-managed passwords must not create a secret-read policy or require a secret metadata lookup."
  }
}

run "separate_policies_authorize_only_their_database_login" {
  command = apply
  variables {
    iam_database_authentication_enabled = true
    iam_read_only_username              = "app_ro"
    iam_read_write_username             = "app_rw"
  }
  assert {
    condition = alltrue([
      for kind, username in { master = "postgres", read_only = "app_ro", read_write = "app_rw" } :
      jsondecode(aws_iam_policy.database_connect[kind].policy).Statement[0].Resource == "arn:aws:rds-db:us-east-1:123456789012:dbuser:db-ABCDEFGHIJKLMNOP/${username}" &&
      jsondecode(aws_iam_policy.database_connect[kind].policy).Statement[0].Action == "rds-db:connect"
    ])
    error_message = "Each managed policy must allow only rds-db:connect as its own login on this database resource ID."
  }
  assert {
    condition     = length(aws_iam_policy.database_connect) == 3
    error_message = "Monitoring must not receive an IAM policy."
  }
  assert {
    condition     = !coalesce(aws_db_instance.this.manage_master_user_password, false) && output.password == var.database_password && output.master_user_secret_arn == null && output.connection_string == null
    error_message = "Enabling IAM must preserve caller-managed passwords while omitting the password-based connection string."
  }
  assert {
    condition     = output.master_secret_read_policy_arn == "" && length(aws_iam_policy.master_secret_read) == 0
    error_message = "IAM login policies must not implicitly grant access to a master password secret."
  }
  assert {
    condition     = output.master_iam_policy_arn == aws_iam_policy.database_connect["master"].arn && output.read_only_iam_policy_arn == aws_iam_policy.database_connect["read_only"].arn && output.read_write_iam_policy_arn == aws_iam_policy.database_connect["read_write"].arn
    error_message = "Each workload grant output must expose the policy for its own login."
  }
}

run "disabled_application_users_have_no_grants" {
  command = apply
  variables {
    iam_database_authentication_enabled = true
    manage_master_user_password         = true
    database_password                   = null
  }
  assert {
    condition     = toset(keys(aws_iam_policy.database_connect)) == toset(["master"])
    error_message = "Only the master grant exists when optional application users are absent."
  }
  assert {
    condition     = aws_db_instance.this.manage_master_user_password && aws_db_instance.this.password == null && output.password == null && output.connection_string == null && output.master_user_secret_arn == "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-example"
    error_message = "IAM and managed passwords must work together, exposing only the master secret ARN."
  }
  assert {
    condition     = length(aws_iam_policy.master_secret_read) == 1 && output.master_secret_read_policy_arn == aws_iam_policy.master_secret_read[0].arn
    error_message = "IAM with managed passwords must publish a separate bootstrap secret-read policy."
  }
}

run "managed_passwords_work_without_iam" {
  command = apply
  variables {
    manage_master_user_password = true
    database_password           = null
  }
  assert {
    condition     = aws_db_instance.this.manage_master_user_password && !aws_db_instance.this.iam_database_authentication_enabled && length(aws_iam_policy.database_connect) == 0
    error_message = "RDS must be able to manage the master password without enabling IAM authentication or creating database-login policies."
  }
  assert {
    condition     = aws_db_instance.this.password == null && output.password == null && output.connection_string == null && output.master_user_secret_arn == "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-example"
    error_message = "Managed passwords must expose the secret ARN without evaluating or publishing a password-based connection string."
  }
  assert {
    condition = jsonencode(jsondecode(aws_iam_policy.master_secret_read[0].policy)) == jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-example"
      }]
    })
    error_message = "The bootstrap policy must allow only reading this instance's master secret, even with IAM login disabled."
  }
  assert {
    condition     = output.master_secret_read_policy_arn == aws_iam_policy.master_secret_read[0].arn
    error_message = "Managed passwords must publish the secret-read policy independently of IAM authentication."
  }
}

run "enabling_managed_passwords_handles_a_pending_master_secret" {
  command   = plan
  state_key = "pending_master_secret"
  variables {
    manage_master_user_password = true
    database_password           = null
  }
  override_resource {
    target          = aws_db_instance.this
    override_during = plan
    values = {
      master_user_secret = []
    }
  }
  assert {
    condition     = output.master_user_secret_arn == null
    error_message = "Enabling managed passwords on an existing instance must plan before RDS creates its secret."
  }
  assert {
    condition     = length(aws_iam_policy.master_secret_read) == 1
    error_message = "The secret-read policy must be planned before an existing instance's managed secret is available."
  }
}

run "rejects_wildcards_in_database_usernames" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_read_only_username              = "app_*"
  }
  expect_failures = [var.iam_read_only_username]
}

run "rejects_application_grants_for_the_master_login" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    iam_read_only_username              = "postgres"
  }
  expect_failures = [aws_iam_policy.database_connect]
}

run "rejects_supplied_password_with_managed_passwords" {
  command = plan
  variables {
    manage_master_user_password = true
  }
  expect_failures = [var.database_password]
}

run "requires_password_when_not_managed_even_with_iam" {
  command = plan
  variables {
    iam_database_authentication_enabled = true
    database_password                   = null
  }
  expect_failures = [var.database_password]
}

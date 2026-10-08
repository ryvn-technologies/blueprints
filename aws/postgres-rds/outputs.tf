output "name" {
  description = "The generated name of the database instance"
  value       = local.name
}

output "endpoint" {
  description = "The connection endpoint (host:port)"
  value       = aws_db_instance.this.endpoint
}

output "host" {
  description = "The hostname of the database instance"
  value       = aws_db_instance.this.address
}

output "password" {
  description = "The caller-provided master password, or null when RDS manages it in Secrets Manager"
  value       = var.manage_master_user_password ? null : aws_db_instance.this.password
  sensitive   = true
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed master password in Secrets Manager, or null when password management is disabled"
  value       = var.manage_master_user_password ? try(aws_db_instance.this.master_user_secret[0].secret_arn, null) : null
}

output "master_secret_read_policy_arn" {
  description = "Managed policy for reading the master password secret. Attach via workload identity role_groups.<group>.policy_arns, or empty when password management is disabled."
  value       = try(aws_iam_policy.master_secret_read[0].arn, "")
}

output "port" {
  description = "The database port"
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "The name of the default database"
  value       = local.database_name
}

output "username" {
  description = "The master username"
  value       = aws_db_instance.this.username
}

output "connection_string" {
  description = "Password-based PostgreSQL connection string, or null when IAM or RDS-managed passwords are enabled"
  value       = var.iam_database_authentication_enabled || var.manage_master_user_password ? null : "postgresql://${replace(urlencode(aws_db_instance.this.username), "+", "%20")}:${replace(urlencode(aws_db_instance.this.password), "+", "%20")}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${local.database_name}?sslmode=require"
  sensitive   = true
}

output "arn" {
  description = "The ARN of the RDS instance"
  value       = aws_db_instance.this.arn
}

output "id" {
  description = "The RDS instance identifier"
  value       = aws_db_instance.this.id
}

output "resource_id" {
  description = "Immutable RDS resource ID used in rds-db:connect ARNs"
  value       = aws_db_instance.this.resource_id
}

output "region" {
  description = "AWS region used when signing IAM database tokens"
  value       = var.aws_region
}

output "master_iam_policy_arn" {
  description = "Master login policy for administrator identities. Attach via workload identity role_groups.<group>.policy_arns, or empty when IAM is disabled."
  value       = try(aws_iam_policy.database_connect["master"].arn, "")
}

output "read_only_iam_policy_arn" {
  description = "Read-only login policy for workload identity role_groups.<group>.policy_arns, or empty when disabled"
  value       = try(aws_iam_policy.database_connect["read_only"].arn, "")
}

output "read_write_iam_policy_arn" {
  description = "Read-write login policy for workload identity role_groups.<group>.policy_arns, or empty when disabled"
  value       = try(aws_iam_policy.database_connect["read_write"].arn, "")
}

# Participation contract for cloud datastore metrics (schema 1): the env's
# hub render reads this output, resolves each target's provider-native id
# through the adapter registry, and allowlists the resulting dimension
# pairs. The instance ARN carries service/region/account — no declaration
# of family, region, or capacity (capacity is read live by the adapter).
output "cloud_metrics" {
  description = "Cloud datastore metrics contract: schema version plus named targets holding provider-native resource ids"
  value = {
    schema = 1
    targets = {
      this = {
        cloud_resource_id = aws_db_instance.this.arn
      }
    }
  }
}

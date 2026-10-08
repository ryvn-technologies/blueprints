output "primary_endpoint" {
  description = "Primary endpoint address for the replication group"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "host" {
  description = "Primary hostname for the cache"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint" {
  description = "Reader endpoint address (load-balanced across read replicas). Only useful when num_cache_clusters > 1."
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "port" {
  description = "The port the cache is listening on"
  value       = var.port
}

output "engine" {
  description = "The cache engine used (redis or valkey)"
  value       = var.engine
}

output "engine_version" {
  description = "The actual engine version deployed"
  value       = local.engine_version
}

output "replication_group_id" {
  description = "The ID of the ElastiCache replication group"
  value       = aws_elasticache_replication_group.this.id
}

output "replication_group_arn" {
  description = "The ARN of the ElastiCache replication group"
  value       = aws_elasticache_replication_group.this.arn
}

output "security_group_id" {
  description = "The ID of the security group created for the cache"
  value       = aws_security_group.cache.id
}

output "connection_url" {
  description = "Connection URL in the format redis(s)://default:token@host:port. Contains no credentials when IAM authentication is enabled; clients supply an IAM username and a SigV4 token at runtime."
  value = local.auth_token != null ? (
    "${var.transit_encryption_enabled ? "rediss" : "redis"}://default:${urlencode(local.auth_token)}@${aws_elasticache_replication_group.this.primary_endpoint_address}:${var.port}"
    ) : (
    "${var.transit_encryption_enabled ? "rediss" : "redis"}://${aws_elasticache_replication_group.this.primary_endpoint_address}:${var.port}"
  )
  sensitive = true
}

output "auth_token" {
  description = "Auth token for the cache cluster, or null when IAM authentication is enabled. Auto-generated if not provided and TLS is enabled."
  value       = local.auth_token
  sensitive   = true
}

output "iam_authentication_enabled" {
  description = "Whether clients authenticate with IAM SigV4 tokens instead of the AUTH token"
  value       = var.iam_authentication_enabled
}

output "user_group_id" {
  description = "ElastiCache user group attached to the replication group, or null when IAM is disabled"
  value       = var.iam_authentication_enabled ? aws_elasticache_user_group.this[0].id : null
}

output "iam_users" {
  description = "IAM cache logins by kind (admin, read_only, read_write). Connect with user_name and a SigV4 token generated for the replication group."
  value = {
    for kind, user in aws_elasticache_user.iam : kind => {
      user_id   = user.user_id
      user_name = user.user_name
      arn       = user.arn
    }
  }
}

output "admin_iam_policy_arn" {
  description = "Full-access login policy for administrator identities. Attach via workload identity role_groups.<group>.policy_arns, or empty when IAM is disabled."
  value       = try(aws_iam_policy.cache_connect["admin"].arn, "")
}

output "read_only_iam_policy_arn" {
  description = "Read-only login policy for workload identity role_groups.<group>.policy_arns, or empty when IAM is disabled"
  value       = try(aws_iam_policy.cache_connect["read_only"].arn, "")
}

output "read_write_iam_policy_arn" {
  description = "Read-write login policy for workload identity role_groups.<group>.policy_arns, or empty when IAM is disabled"
  value       = try(aws_iam_policy.cache_connect["read_write"].arn, "")
}

# Participation contract for cloud datastore metrics (schema 1): the env's
# hub render resolves each target's provider-native id and allowlists the
# resulting dimension pairs. Member nodes and the group are separate
# targets — cluster identity and group identity are never interchangeable.
# Targets are keyed by the member id, not position: node ids are stable
# across scale changes while indices re-map when a member leaves.
# Member ARNs are constructed (member_clusters exposes ids only); the group
# emits its own arn. Capacity is read live by the adapter, not declared.
output "cloud_metrics" {
  description = "Cloud datastore metrics contract: schema version plus named targets holding provider-native resource ids"
  value = {
    schema = 1
    targets = merge(
      {
        for id in aws_elasticache_replication_group.this.member_clusters :
        id => {
          cloud_resource_id = "arn:${data.aws_partition.current.partition}:elasticache:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster:${id}"
        }
      },
      {
        group = {
          cloud_resource_id = aws_elasticache_replication_group.this.arn
        }
      },
    )
  }
}

output "primary_endpoint" {
  description = "Primary endpoint address for the replication group"
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
  description = "Connection URL in the format redis(s)://host:port"
  value       = "${var.transit_encryption_enabled ? "rediss" : "redis"}://${aws_elasticache_replication_group.this.primary_endpoint_address}:${var.port}"
}

output "auth_token" {
  description = "Auth token for the cache cluster. Auto-generated if not provided and TLS is enabled."
  value       = local.auth_token
  sensitive   = true
}

output "name" {
  description = "The generated name of the Redis cache"
  value       = local.name
}

output "hostname" {
  description = "The hostname of the Redis cache"
  value       = azurerm_redis_cache.this.hostname
}

output "host" {
  description = "The hostname of the Redis cache"
  value       = azurerm_redis_cache.this.hostname
}

output "port" {
  description = "The SSL port of the Redis cache"
  value       = azurerm_redis_cache.this.ssl_port
}

output "primary_access_key" {
  description = "The primary access key for the Redis cache"
  value       = azurerm_redis_cache.this.primary_access_key
  sensitive   = true
}

output "auth_token" {
  description = "Auth token for the cache (alias for primary_access_key)"
  value       = azurerm_redis_cache.this.primary_access_key
  sensitive   = true
}

output "connection_url" {
  description = "Connection URL in the format rediss://:key@host:port"
  value       = "rediss://:${urlencode(azurerm_redis_cache.this.primary_access_key)}@${azurerm_redis_cache.this.hostname}:${azurerm_redis_cache.this.ssl_port}"
  sensitive   = true
}

output "id" {
  description = "The Azure resource ID of the Redis cache"
  value       = azurerm_redis_cache.this.id
}

output "name" {
  description = "The generated name of the Managed Redis instance"
  value       = local.name
}

output "hostname" {
  description = "The hostname of the Managed Redis instance"
  value       = azurerm_managed_redis.this.hostname
}

output "host" {
  description = "The hostname of the Managed Redis instance"
  value       = azurerm_managed_redis.this.hostname
}

output "port" {
  description = "The TLS port of the default database"
  value       = azurerm_managed_redis.this.default_database[0].port
}

output "primary_access_key" {
  description = "The primary access key for the default database"
  value       = azurerm_managed_redis.this.default_database[0].primary_access_key
  sensitive   = true
}

output "auth_token" {
  description = "Auth token for the cache (alias for primary_access_key)"
  value       = azurerm_managed_redis.this.default_database[0].primary_access_key
  sensitive   = true
}

output "connection_url" {
  description = "Connection URL in the format rediss://:key@host:port"
  value       = "rediss://:${urlencode(azurerm_managed_redis.this.default_database[0].primary_access_key)}@${azurerm_managed_redis.this.hostname}:${azurerm_managed_redis.this.default_database[0].port}"
  sensitive   = true
}

output "id" {
  description = "The Azure resource ID of the Managed Redis instance"
  value       = azurerm_managed_redis.this.id
}

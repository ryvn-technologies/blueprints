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
  description = "The primary access key for the default database, or null when access-key authentication is disabled"
  value       = var.access_keys_authentication_enabled ? azurerm_managed_redis.this.default_database[0].primary_access_key : null
  sensitive   = true
}

output "auth_token" {
  description = "Auth token for the cache (alias for primary_access_key), or null when access-key authentication is disabled"
  value       = var.access_keys_authentication_enabled ? azurerm_managed_redis.this.default_database[0].primary_access_key : null
  sensitive   = true
}

output "connection_url" {
  description = "Connection URL in the format rediss://:key@host:port, or rediss://host:port without credentials when access-key authentication is disabled"
  value = var.access_keys_authentication_enabled ? (
    "rediss://:${urlencode(azurerm_managed_redis.this.default_database[0].primary_access_key)}@${azurerm_managed_redis.this.hostname}:${azurerm_managed_redis.this.default_database[0].port}"
    ) : (
    "rediss://${azurerm_managed_redis.this.hostname}:${azurerm_managed_redis.this.default_database[0].port}"
  )
  sensitive = true
}

output "access_keys_authentication_enabled" {
  description = "Whether access-key (password) authentication is enabled on the default database"
  value       = var.access_keys_authentication_enabled
}

output "entra_token_scope" {
  description = "OAuth scope clients request when acquiring an Entra token for the cache"
  value       = "https://redis.azure.com/.default"
}

output "entra_principals" {
  description = "Principals granted the default access policy, by caller alias. Use object_id as the Redis username and an Entra token (entra_token_scope) as the password."
  value = {
    for alias, assignment in azurerm_managed_redis_access_policy_assignment.this : alias => {
      object_id     = assignment.object_id
      assignment_id = assignment.id
    }
  }
}

output "id" {
  description = "The Azure resource ID of the Managed Redis instance"
  value       = azurerm_managed_redis.this.id
}

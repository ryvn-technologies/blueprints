output "name" {
  description = "The generated name of the Redis instance"
  value       = local.name
}

output "host" {
  description = "The IP address of the Redis instance"
  value       = google_redis_instance.this.host
}

output "port" {
  description = "The port of the Redis instance"
  value       = google_redis_instance.this.port
}

output "auth_string" {
  description = "AUTH string for the Redis instance (when auth_enabled is true)"
  value       = var.auth_enabled ? google_redis_instance.this.auth_string : null
  sensitive   = true
}

output "auth_token" {
  description = "Auth token for the cache (alias for auth_string)"
  value       = var.auth_enabled ? google_redis_instance.this.auth_string : null
  sensitive   = true
}

output "connection_url" {
  description = "Connection URL in the format redis(s)://:auth@host:port"
  value = var.auth_enabled ? (
    "${var.transit_encryption_enabled ? "rediss" : "redis"}://:${urlencode(google_redis_instance.this.auth_string)}@${google_redis_instance.this.host}:${google_redis_instance.this.port}"
    ) : (
    "${var.transit_encryption_enabled ? "rediss" : "redis"}://${google_redis_instance.this.host}:${google_redis_instance.this.port}"
  )
  sensitive = true
}

output "server_ca_certs" {
  description = "TLS CA certificates for the Redis instance (when transit encryption is enabled)"
  value       = var.transit_encryption_enabled ? google_redis_instance.this.server_ca_certs : []
  sensitive   = true
}

output "id" {
  description = "The Memorystore Redis instance ID"
  value       = google_redis_instance.this.id
}

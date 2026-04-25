output "name" {
  description = "The generated name of the Cloud SQL instance"
  value       = local.name
}

output "connection_name" {
  description = "The connection name (project:region:instance) used by Cloud SQL Auth Proxy"
  value       = google_sql_database_instance.this.connection_name
}

output "host" {
  description = "The primary IP address (private IP preferred, falls back to public)"
  value       = var.private_network != null ? google_sql_database_instance.this.private_ip_address : google_sql_database_instance.this.public_ip_address
}

output "endpoint" {
  description = "The connection endpoint (host:port)"
  value       = "${var.private_network != null ? google_sql_database_instance.this.private_ip_address : google_sql_database_instance.this.public_ip_address}:5432"
}

output "private_ip_address" {
  description = "The private IP address (empty if private_network is not configured)"
  value       = google_sql_database_instance.this.private_ip_address
}

output "public_ip_address" {
  description = "The public IP address (empty if publicly_accessible is false)"
  value       = google_sql_database_instance.this.public_ip_address
}

output "password" {
  description = "The database password"
  value       = var.database_password
  sensitive   = true
}

output "port" {
  description = "The database port"
  value       = 5432
}

output "database_name" {
  description = "The name of the default database"
  value       = var.database_name
}

output "username" {
  description = "The database username"
  value       = trimspace(var.database_username)
}

output "connection_string" {
  description = "Full PostgreSQL connection string"
  value       = "postgresql://${trimspace(var.database_username)}:${var.database_password}@${var.private_network != null ? google_sql_database_instance.this.private_ip_address : google_sql_database_instance.this.public_ip_address}:5432/${coalesce(var.database_name, "postgres")}?sslmode=require"
  sensitive   = true
}

output "id" {
  description = "The Cloud SQL instance self_link"
  value       = google_sql_database_instance.this.self_link
}

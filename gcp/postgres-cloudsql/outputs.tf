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
  description = "The built-in database password, or null when none is supplied"
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
  description = "The built-in password database username, or null when no password is supplied"
  value       = local.has_database_password ? local.database_username : null
}

output "connection_string" {
  description = "Full PostgreSQL password connection string, or null when no password is supplied"
  value       = local.has_database_password ? "postgresql://${replace(urlencode(local.database_username), "+", "%20")}:${replace(urlencode(var.database_password), "+", "%20")}@${var.private_network != null ? google_sql_database_instance.this.private_ip_address : google_sql_database_instance.this.public_ip_address}:5432/${coalesce(var.database_name, "postgres")}?sslmode=require" : null
  sensitive   = true
}

output "id" {
  description = "The Cloud SQL instance self_link"
  value       = google_sql_database_instance.this.self_link
}

output "project_id" {
  description = "Project containing the Cloud SQL instance, used for caller-managed IAM bindings"
  value       = var.project_id
}

output "instance_resource_name" {
  description = "Cloud SQL resource name for IAM conditions; distinct from the proxy connection_name"
  value       = "projects/${var.project_id}/instances/${google_sql_database_instance.this.name}"
}

output "iam_database_users" {
  description = "Registered IAM accounts by input key: SQL username, full principal email, IAM member identifier, and account type. Empty when no accounts are managed."
  value = {
    for key, user in google_sql_user.iam : key => {
      username = user.name
      email    = local.iam_database_users[key].email
      member   = local.iam_database_users[key].member
      type     = user.type
    }
  }
}

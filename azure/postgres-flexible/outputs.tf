output "name" {
  description = "The generated name of the database server"
  value       = local.name
}

output "fqdn" {
  description = "The fully qualified domain name of the server"
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "host" {
  description = "The hostname of the database server"
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "endpoint" {
  description = "The connection endpoint (host:port)"
  value       = "${azurerm_postgresql_flexible_server.this.fqdn}:5432"
}

output "password" {
  description = "The administrator password"
  value       = azurerm_postgresql_flexible_server.this.administrator_password
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
  description = "The administrator login"
  value       = azurerm_postgresql_flexible_server.this.administrator_login
}

output "connection_string" {
  description = "Full PostgreSQL connection string"
  value       = "postgresql://${azurerm_postgresql_flexible_server.this.administrator_login}:${azurerm_postgresql_flexible_server.this.administrator_password}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${coalesce(var.database_name, "postgres")}"
  sensitive   = true
}

output "id" {
  description = "The Azure resource ID of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.this.id
}

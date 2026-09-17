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
  description = "The local administrator password, or null when password authentication is disabled"
  value       = var.password_authentication_enabled ? azurerm_postgresql_flexible_server.this.administrator_password : null
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
  description = "The local administrator login, or null when password authentication is disabled. Entra logins are in entra_administrators."
  value       = var.password_authentication_enabled ? azurerm_postgresql_flexible_server.this.administrator_login : null
}

output "connection_string" {
  description = "Password-based PostgreSQL connection string, or null when password authentication is disabled"
  value       = var.password_authentication_enabled && var.database_username != null && var.database_password != null ? "postgresql://${replace(urlencode(azurerm_postgresql_flexible_server.this.administrator_login), "+", "%20")}:${replace(urlencode(azurerm_postgresql_flexible_server.this.administrator_password), "+", "%20")}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${coalesce(var.database_name, "postgres")}?sslmode=require" : null
  sensitive   = true
}

output "id" {
  description = "The Azure resource ID of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.this.id
}

output "entra_tenant_id" {
  description = "The Microsoft Entra tenant trusted by the server, or null when Entra authentication is disabled"
  value       = var.entra_tenant_id
}

output "entra_administrators" {
  description = "Provisioned Entra administrators by caller alias. Use principal_name as the PostgreSQL login and acquire a token at runtime."
  value = {
    for name, administrator in azurerm_postgresql_flexible_server_active_directory_administrator.this : name => {
      object_id      = administrator.object_id
      principal_name = administrator.principal_name
      principal_type = administrator.principal_type
    }
  }
}

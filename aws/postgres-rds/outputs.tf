output "name" {
  description = "The generated name of the database instance"
  value       = local.name
}

output "endpoint" {
  description = "The connection endpoint (host:port)"
  value       = aws_db_instance.this.endpoint
}

output "host" {
  description = "The hostname of the database instance"
  value       = aws_db_instance.this.address
}

output "password" {
  description = "The master password"
  value       = aws_db_instance.this.password
  sensitive   = true
}

output "port" {
  description = "The database port"
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "The name of the default database"
  value       = aws_db_instance.this.db_name
}

output "username" {
  description = "The master username"
  value       = aws_db_instance.this.username
}

output "connection_string" {
  description = "Full PostgreSQL connection string"
  value       = "postgresql://${aws_db_instance.this.username}:${aws_db_instance.this.password}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${aws_db_instance.this.db_name}?sslmode=require"
  sensitive   = true
}

output "arn" {
  description = "The ARN of the RDS instance"
  value       = aws_db_instance.this.arn
}

output "id" {
  description = "The RDS instance identifier"
  value       = aws_db_instance.this.id
}

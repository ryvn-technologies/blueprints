output "launch_template_id" {
  description = "EC2 launch template ID for in-network task runners."
  value       = aws_launch_template.runner.id
}

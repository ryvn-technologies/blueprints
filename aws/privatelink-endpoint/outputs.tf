output "vpc_endpoint_id" {
  description = "ID of the VPC endpoint (vpce-<id>)."
  value       = aws_vpc_endpoint.endpoint_service.id
}

output "vpc_endpoint_state" {
  description = "State of the VPC endpoint: available once the endpoint service accepts it."
  value       = aws_vpc_endpoint.endpoint_service.state
}

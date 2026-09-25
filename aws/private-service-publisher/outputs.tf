output "publisher_id" {
  description = "Endpoint service name (com.amazonaws.vpce.<region>.vpce-svc-<id>). A consumer connects to it."
  value       = aws_vpc_endpoint_service.internal_gateway.service_name
}

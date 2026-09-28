output "endpoint_service_name" {
  description = "Name of the endpoint service (com.amazonaws.vpce.<region>.vpce-svc-<id>). Consumers connect to it."
  value       = aws_vpc_endpoint_service.published_load_balancer.service_name
}

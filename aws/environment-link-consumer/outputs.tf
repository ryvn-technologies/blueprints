output "consumer_id" {
  description = "ID of the interface endpoint (vpce-<id>)."
  value       = aws_vpc_endpoint.publisher.id
}

output "link_state" {
  description = "Connection state: available when connected."
  value       = aws_vpc_endpoint.publisher.state
}

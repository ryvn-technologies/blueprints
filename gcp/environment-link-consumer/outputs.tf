output "consumer_id" {
  description = "ID of the PSC endpoint's forwarding rule (projects/<project>/regions/<region>/forwardingRules/<name>)."
  value       = module.psc_endpoint.forwarding_rule_id
}

output "link_state" {
  description = "Connection state: ACCEPTED when connected, PENDING until the publisher allows this project."
  value       = data.google_compute_forwarding_rule.psc_endpoint.psc_connection_status
}

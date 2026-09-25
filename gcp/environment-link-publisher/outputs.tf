output "publisher_id" {
  description = "Service attachment ID (projects/<project>/regions/<region>/serviceAttachments/<name>). A consumer connects to it."
  value       = module.psc_producer.service_attachment_id
}

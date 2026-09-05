# Cluster outputs
output "cluster_endpoint" {
  description = "Endpoint for your Kubernetes API server"
  value       = module.gke.endpoint
  sensitive   = true
}

output "cluster_endpoint_dns" {
  description = "DNS-based endpoint for your Kubernetes API server, gated by IAM"
  value       = module.gke.endpoint_dns
}

output "cluster_ca_certificate" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.gke.ca_certificate
  sensitive   = true
}

output "cluster_name" {
  description = "The name of the GKE cluster"
  value       = module.gke.name
}

output "cluster_region" {
  description = "The GCP region where the GKE cluster is deployed"
  value       = var.region
}

output "deletion_protection" {
  description = "Whether the cluster and populated DNS zones are protected from deletion. Ryvn refuses to deprovision the environment while this is true."
  value       = var.deletion_protection
}

output "cluster_secrets_encryption" {
  description = "Kubernetes Secrets encryption: whether a Cloud KMS key is in use and which one. key_name is null when Secrets use Google's default encryption only."
  value = {
    customer_managed_key = local.cluster_secrets_encrypted
    key_name             = local.cluster_secrets_kms_key
  }
}

# VPC outputs
output "vpc" {
  description = "A map of vpc attributes including network details, subnets, and secondary ranges"
  value = {
    # Core VPC information
    name      = module.gcp-network.network_name
    id        = module.gcp-network.network_id
    self_link = module.gcp-network.network_self_link # Required for many GCP resources

    # Flattened subnet lists for easy consumption
    subnet_ids   = module.gcp-network.subnets_ids
    subnet_cidrs = module.gcp-network.subnets_ips

    # Detailed subnet information
    subnets = [{
      name   = module.gcp-network.subnets_names[0]
      id     = module.gcp-network.subnets_ids[0]
      cidr   = module.gcp-network.subnets_ips[0]
      region = var.region
    }]
    nat_public_ips = [google_compute_address.nat.address]
    outbound_ips   = [google_compute_address.nat.address]

    # GCP-specific secondary ranges for GKE
    secondary_ranges = {
      pods = {
        name = local.pods_range_name
        cidr = var.pod_cidr
      }
      services = {
        name = local.svc_range_name
        cidr = var.service_cidr
      }
    }
  }
}

output "outbound_ips" {
  description = "Public IPs used for outbound internet traffic from workloads in this environment."
  value       = [google_compute_address.nat.address]
}

# DNS outputs
output "public_domain" {
  description = "The public domain for the cluster"
  value = var.skip_dns_provisioning ? null : {
    name        = trim(google_dns_managed_zone.public[0].dns_name, ".")
    fqdn        = google_dns_managed_zone.public[0].dns_name
    id          = google_dns_managed_zone.public[0].id
    nameservers = google_dns_managed_zone.public[0].name_servers
  }
}

output "internal_domain" {
  description = "The internal domain for the cluster"
  value = var.skip_dns_provisioning ? null : {
    name = trim(google_dns_managed_zone.internal[0].dns_name, ".")
    fqdn = google_dns_managed_zone.internal[0].dns_name
    id   = google_dns_managed_zone.internal[0].id
  }
}

# Service account outputs
output "ryvn_agent_service_account_email" {
  description = "Email of the GCP service account for ryvn-agent"
  value       = google_service_account.ryvn_agent.email
}

output "external_dns_service_account_email" {
  description = "Email of the GCP service account for external-dns"
  value       = google_service_account.external_dns.email
}

output "cert_manager_service_account_email" {
  description = "Email of the GCP service account for cert-manager"
  value       = google_service_account.cert_manager.email
}

output "ryvn_agent_service_account" {
  description = "The service account details for Ryvn Agent (GCP equivalent of IAM role)"
  value = {
    email     = google_service_account.ryvn_agent.email
    id        = google_service_account.ryvn_agent.id
    unique_id = google_service_account.ryvn_agent.unique_id
  }
}

output "cert_manager_identity" {
  description = "The service account details for cert-manager (GCP equivalent of a managed identity)"
  value = {
    email     = google_service_account.cert_manager.email
    id        = google_service_account.cert_manager.id
    unique_id = google_service_account.cert_manager.unique_id
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  # Cut so every derived resource name stays within GCP's 63-character limit.
  resource_name_prefix = "${trim(substr(var.name_prefix, 0, 31), "-")}-${random_id.suffix.hex}"

  publisher_region = provider::google::region_from_id(var.publisher_id)
  psc_endpoint_ip  = module.psc_endpoint.ip_address
}

resource "terraform_data" "publisher_region_check" {
  lifecycle {
    precondition {
      condition     = local.publisher_region == var.subnetwork_region
      error_message = "This environment is in ${var.subnetwork_region}, but the publisher is in ${local.publisher_region}. Both must be in the same region."
    }
  }
}

module "psc_endpoint" {
  source  = "terraform-google-modules/network/google//modules/private-service-connect-endpoints-for-published-services"
  version = "18.3.0"

  project_id           = var.project_id
  region               = local.publisher_region
  network              = var.network
  subnetwork           = var.subnetwork
  address_name         = "${local.resource_name_prefix}-psc-endpoint"
  forwarding_rule_name = "${local.resource_name_prefix}-psc-endpoint"
  service_attachment   = var.publisher_id
  psc_global_access    = false
}

resource "google_compute_firewall" "allow_http_to_psc_endpoint" {
  project            = var.project_id
  name               = "${local.resource_name_prefix}-endpoint-allow-http"
  description        = "Allow HTTP to the private service endpoint"
  network            = var.network
  direction          = "EGRESS"
  priority           = 900
  destination_ranges = ["${local.psc_endpoint_ip}/32"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource "google_compute_firewall" "deny_other_to_psc_endpoint" {
  project            = var.project_id
  name               = "${local.resource_name_prefix}-endpoint-deny-other"
  description        = "Deny everything else to the private service endpoint"
  network            = var.network
  direction          = "EGRESS"
  priority           = 910
  destination_ranges = ["${local.psc_endpoint_ip}/32"]

  deny {
    protocol = "all"
  }
}

resource "google_dns_managed_zone" "publisher_domain" {
  project     = var.project_id
  name        = "${local.resource_name_prefix}-publisher-domain"
  dns_name    = "${var.publisher_domain}."
  description = "Internal names of the publishing environment, resolved to the PSC endpoint"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = var.network
    }
  }
}

resource "google_dns_record_set" "publisher_domain_wildcard" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.publisher_domain.name
  name         = "*.${var.publisher_domain}."
  type         = "A"
  ttl          = 300
  rrdatas      = [local.psc_endpoint_ip]
}

# Looked up by ID, which is unknown until the endpoint exists, so the first plan defers this read to apply.
data "google_compute_forwarding_rule" "psc_endpoint" {
  project = var.project_id
  region  = local.publisher_region
  name    = provider::google::name_from_id(module.psc_endpoint.forwarding_rule_id)
}

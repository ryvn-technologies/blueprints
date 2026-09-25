locals {
  # Not random_id: the PSC producer module keys NAT subnets by name, so names must be known at plan time. Hashing the
  # network keeps names unique across environments that share a project; the cut keeps every name within 63 characters.
  resource_name_prefix = "${trim(substr(var.name_prefix, 0, 31), "-")}-${substr(sha256("${var.network}/${var.name_prefix}"), 0, 8)}"

  # GKE writes the owning Service into each forwarding rule's description as JSON. Its older load balancer controller
  # uses the first key, the newer one the second.
  gateway_forwarding_rule_names = [
    for rule in data.google_compute_forwarding_rules.in_region.rules : rule.name
    if rule.network == var.network && var.kubernetes_service == try(
      jsondecode(rule.description)["kubernetes.io/service-name"],
      jsondecode(rule.description)["networking.gke.io/service-name"],
      null,
    )
  ]

  psc_nat_subnets = [{
    subnet_name = "${local.resource_name_prefix}-psc-nat"
    ipv4_range  = var.nat_subnet_cidr
  }]

  allowed_consumer_projects = length(var.allowed_projects) > 0 ? distinct(var.allowed_projects) : [var.project_id]
  consumer_accept_lists = [
    for project in local.allowed_consumer_projects : {
      project_id_or_num = project
      connection_limit  = 10
    }
  ]
}

data "google_compute_forwarding_rules" "in_region" {
  project = var.project_id
  region  = var.region
}

data "google_compute_forwarding_rule" "gateway" {
  project = var.project_id
  region  = var.region
  name    = local.gateway_forwarding_rule_names[0]

  lifecycle {
    precondition {
      condition     = length(local.gateway_forwarding_rule_names) == 1
      error_message = length(local.gateway_forwarding_rule_names) == 0 ? "This environment has no internal gateway running. Contact Ryvn support to turn it on, then install again." : "This environment has more than one internal gateway load balancer. Contact Ryvn support."
    }
  }
}

module "psc_producer" {
  source  = "terraform-google-modules/network/google//modules/private-service-connect-producer"
  version = "18.3.0"

  project_id            = var.project_id
  region                = var.region
  network               = var.network
  name                  = local.resource_name_prefix
  nat_subnets           = local.psc_nat_subnets
  target_service        = data.google_compute_forwarding_rule.gateway.self_link
  connection_preference = "ACCEPT_MANUAL"
  consumer_accept_lists = local.consumer_accept_lists
  reconcile_connections = true
  enable_proxy_protocol = false
}

resource "google_compute_firewall" "allow_http_from_psc_nat" {
  project       = var.project_id
  name          = "${local.resource_name_prefix}-psc-nat-allow-http"
  description   = "Private service: HTTP from consumers"
  network       = var.network
  direction     = "INGRESS"
  source_ranges = [var.nat_subnet_cidr]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

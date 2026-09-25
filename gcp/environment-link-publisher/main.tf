locals {
  # Keeps every derived resource name within GCP's 63-character limit.
  resource_name_prefix = length(var.name_prefix) <= 40 ? var.name_prefix : "${substr(var.name_prefix, 0, 33)}-${substr(sha256(var.name_prefix), 0, 6)}"

  # GKE writes the Service into the rule's description, e.g. {"kubernetes.io/service-name":"ryvn-system/internal-ryvn-istio"}.
  gateway_forwarding_rule_names = [
    for rule in data.google_compute_forwarding_rules.in_region.rules : rule.name
    if rule.network == var.network && try(strcontains(rule.description, "\"${var.gateway_service}\""), false)
  ]

  psc_nat_subnets = [{
    subnet_name = "${local.resource_name_prefix}-psc-nat"
    ipv4_range  = var.nat_subnet_cidr
  }]

  allowed_consumer_projects = length(var.allowed_consumers) > 0 ? distinct(var.allowed_consumers) : [var.project_id]
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

# The list above doesn't include load_balancing_scheme, so the match is read back by name.
data "google_compute_forwarding_rule" "gateway" {
  project = var.project_id
  region  = var.region
  name    = local.gateway_forwarding_rule_names[0]

  lifecycle {
    precondition {
      condition     = length(local.gateway_forwarding_rule_names) == 1
      error_message = length(local.gateway_forwarding_rule_names) == 0 ? "This environment has no internal gateway running. Contact Ryvn support to turn it on, then install again." : "This environment has more than one internal gateway load balancer. Contact Ryvn support."
    }

    postcondition {
      condition     = self.load_balancing_scheme == "INTERNAL"
      error_message = "This environment's internal gateway is public, so it can't be published. Contact Ryvn support."
    }

    # GKE recreates the rule when the Service's ports change, which a service attachment blocks.
    postcondition {
      condition     = self.all_ports || contains(try(tolist(self.ports), []), "80")
      error_message = "This environment's internal gateway doesn't serve HTTP yet. Contact Ryvn support to upgrade it, then install again."
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
  description   = "Environment link: HTTP from connected environments"
  network       = var.network
  direction     = "INGRESS"
  source_ranges = [var.nat_subnet_cidr]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

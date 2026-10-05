locals {
  network_name    = "gke-network-${var.environment}"
  subnet_name     = "gke-subnet-${var.environment}"
  pods_range_name = "pod-ranges-${var.environment}"
  svc_range_name  = "services-ranges-${var.environment}"
  psa_range_name  = "private-services-${var.environment}"
}

module "gcp-network" {
  source = "terraform-google-modules/network/google"
  # Exact pin, see module "gke".
  version = "18.2.0"

  project_id   = var.project_id
  network_name = local.network_name

  subnets = [
    {
      subnet_name                      = local.subnet_name
      subnet_ip                        = var.subnet_cidr
      subnet_region                    = var.region
      private_ip_google_access         = !local.egress_firewall_enabled
      subnet_private_access            = !local.egress_firewall_enabled
      subnet_flow_logs                 = var.flow_logs.enable
      subnet_flow_logs_interval        = var.flow_logs.interval
      subnet_flow_logs_sampling        = var.flow_logs.sampling
      subnet_flow_logs_metadata        = var.flow_logs.metadata
      subnet_flow_logs_filter          = var.flow_logs.filter
      subnet_flow_logs_metadata_fields = var.flow_logs.metadata_fields
    }
  ]

  # Secondary ranges are required for GKE VPC-native clusters
  secondary_ranges = {
    (local.subnet_name) = [
      {
        range_name    = local.pods_range_name
        ip_cidr_range = var.pod_cidr
      },
      {
        range_name    = local.svc_range_name
        ip_cidr_range = var.service_cidr
      },
    ]
  }

  # Managed egress evaluates its firewall policy before classic rules and
  # replaces the allow-all egress rule; disabled mode keeps both unchanged.
  network_firewall_policy_enforcement_order = local.egress_firewall_enabled ? "BEFORE_CLASSIC_FIREWALL" : null

  firewall_rules = concat([
    {
      name        = "allow-internal-${var.environment}"
      description = "Allow internal traffic for ${var.environment}"
      direction   = "INGRESS"
      ranges      = [var.subnet_cidr, var.pod_cidr, var.service_cidr]
      allow = [{
        protocol = "tcp"
        ports    = []
        },
        {
          protocol = "udp"
          ports    = []
        },
        {
          protocol = "icmp"
          ports    = []
      }]
    }],
    local.egress_firewall_enabled ? [] : [{
      name        = "allow-egress-${var.environment}"
      description = "Allow all egress traffic"
      direction   = "EGRESS"
      ranges      = ["0.0.0.0/0"]
      allow = [{
        protocol = "tcp"
        ports    = []
        },
        {
          protocol = "udp"
          ports    = []
        },
        {
          protocol = "icmp"
          ports    = []
      }]
    }],
  )
}

resource "google_project_service" "service_networking" {
  project            = var.project_id
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

# Reserve an internal range once per VPC for Google-managed services like Cloud SQL.
resource "google_compute_global_address" "private_services_access" {
  name          = local.psa_range_name
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = module.gcp-network.network_self_link
}

resource "google_service_networking_connection" "private_services_access" {
  network                 = module.gcp-network.network_self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services_access.name]
  update_on_creation_fail = true

  depends_on = [google_project_service.service_networking]
}

# Cloud NAT configuration for stable outbound IPs
resource "google_compute_address" "nat" {
  name         = "nat-ip-${var.environment}"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "google_compute_router" "router" {
  name    = "nat-router-${var.environment}"
  region  = var.region
  network = module.gcp-network.network_self_link
}

# Disabled mode without subnet groups keeps NAT on every subnet. Otherwise NAT
# serves the cluster subnet plus, with managed egress, attached groups, and
# carries both inspected web and network_allow tuples. Unattached groups stay
# local-only. Address ownership never depends on firewall or optional layers.
locals {
  outbound_ips = [google_compute_address.nat.address]

  nat_all_subnetworks = !local.egress_firewall_enabled && length(local.active_subnet_groups) == 0
  nat_subnetworks = merge(
    { cluster = module.gcp-network.subnets_self_links[0] },
    local.egress_firewall_enabled ? {
      for key, attachment in var.egress_attachments : key => google_compute_subnetwork.additional_group[attachment.subnet_group_key].self_link
    } : {},
  )
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat-gateway-${var.environment}"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.nat.self_link]
  source_subnetwork_ip_ranges_to_nat = local.nat_all_subnetworks ? "ALL_SUBNETWORKS_ALL_IP_RANGES" : "LIST_OF_SUBNETWORKS"

  dynamic "subnetwork" {
    for_each = local.nat_all_subnetworks ? {} : local.nat_subnetworks
    content {
      name                    = subnetwork.value
      source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
    }
  }

  log_config {
    enable = true
    filter = local.egress_firewall_enabled ? "ALL" : "ERRORS_ONLY"
  }
}

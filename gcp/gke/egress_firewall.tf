# ============================================================================
# Default-deny cloud egress firewall (managed mode)
# ============================================================================
# Design: docs-internal/changes/cloud-egress-firewall/gcp-ngfw-base.md
#
# Root responsibilities: input validation helpers, the GKE platform baseline,
# additional subnet group allocation, permission classes and the public
# `egress_firewall` output. vpc.tf owns the classic firewall rules, the
# network's policy enforcement order and Cloud NAT scope. The child module owns
# the native URL profiles, zonal endpoints and firewall policy compilation.

locals {
  egress_firewall_enabled = var.egress_firewall.enabled

  # The same ASCII-normalized Public Suffix List as AWS and Azure, vendored so
  # the published module validates without fetching data at plan/apply time.
  # A map, not a set: contains() on a ~10k-entry set costs seconds per plan.
  egress_public_suffixes = {
    for line in split("\n", file("${path.module}/modules/egress-firewall/public_suffix_list.dat")) :
    trimspace(line) => true... if trimspace(line) != "" && !startswith(line, "//")
  }

  # Never a network_allow destination: the reserved, private and link-local
  # ranges AWS and Azure reject, plus this environment's own ranges.
  egress_rejected_destination_cidrs = [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4",
    var.subnet_cidr,
    var.pod_cidr,
    var.service_cidr,
  ]

  # Zonal agent endpoints: every zone the node pools can use.
  egress_zones = sort(distinct(concat(length(var.zones) > 0 ? var.zones : flatten(data.google_compute_zones.egress[*].names), tolist(var.egress_firewall.additional_workload_zones))))

  # Cluster-only platform destinations; native NGFW bootstrap remains a live
  # validation gate. Registry hosts match the AWS and Azure baselines.
  builtin_platform_https_domains = toset(concat([
    "container.googleapis.com",
    "${var.region}-autoscaling.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudtrace.googleapis.com",
    # Workload Identity token exchange for the agent, external-dns and cert-manager.
    "sts.googleapis.com",
    "iamcredentials.googleapis.com",
    "oauth2.googleapis.com",
    # gke.gcr.io, regional Artifact Registry mirrors and mirror.gcr.io (the
    # GKE Docker Hub mirror); image layers are served from storage.googleapis.com.
    "gcr.io",
    "*.gcr.io",
    "*.pkg.dev",
    "storage.googleapis.com",
    # external-dns and cert-manager DNS-01.
    "dns.googleapis.com",
    "acme-v02.api.letsencrypt.org",
    "auth.docker.io",
    "registry-1.docker.io",
    # Hub canonicalizes Docker Hub OCI chart repos to index.docker.io
    # (pkg/registry.CanonicalHost); docker.io is the same registry's short name.
    "index.docker.io",
    "docker.io",
    "production.cloudflare.docker.com",
    "production.cloudfront.docker.com",
    "docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com",
    "registry.k8s.io",
    "cdn.registry.k8s.io",
    "ghcr.io",
    "pkg-containers.githubusercontent.com",
    "registry.istio.io",
    "quay.io",
    "*.quay.io",
    # Ryvn's public chart repository and registry.
    "charts.ryvn.app",
    "registry.ryvn.app",
  ], [for zone in local.egress_zones : "${zone}-agentcommunication.googleapis.com"]))

  # Caller-supplied hub/collector hostnames join the built-ins; they can add to
  # the baseline but never remove from it.
  platform_https_domains = setunion(local.builtin_platform_https_domains, var.platform_https_domains)

  # Additional subnet groups: sequential aligned allocations inside
  # additional_subnet_groups_cidr, retired entries included.
  additional_subnet_prefix = tonumber(split("/", var.additional_subnet_groups_cidr)[1])
  additional_subnet_prefixes_valid = alltrue([for group in var.additional_subnet_groups :
    group.ipv4_prefix_length == floor(group.ipv4_prefix_length) &&
    group.ipv4_prefix_length >= local.additional_subnet_prefix && group.ipv4_prefix_length <= 29
  ])
  additional_subnet_newbits = [for group in var.additional_subnet_groups : group.ipv4_prefix_length - local.additional_subnet_prefix]
  additional_subnet_fits    = local.additional_subnet_prefixes_valid && can(cidrsubnets(var.additional_subnet_groups_cidr, local.additional_subnet_newbits...))
  additional_subnet_cidrs   = local.additional_subnet_fits && length(var.additional_subnet_groups) > 0 ? cidrsubnets(var.additional_subnet_groups_cidr, local.additional_subnet_newbits...) : []
  additional_subnet_geometry = { for position, group in var.additional_subnet_groups : group.name => {
    position           = position
    ipv4_prefix_length = group.ipv4_prefix_length
    ipv4_cidr          = try(local.additional_subnet_cidrs[position], null)
  } }
  active_subnet_groups    = { for group in var.additional_subnet_groups : group.name => group if !group.retired }
  additional_subnet_names = { for name in keys(local.active_subnet_groups) : name => "ext-${replace(name, "_", "-")}-${var.environment}" }

  # Cluster class sources: node primary range and the pod range. GKE SNATs pod
  # egress to the node address; both ranges are listed so either form matches.
  egress_cluster_sources = [var.subnet_cidr, var.pod_cidr]

  egress_classes = local.egress_firewall_enabled ? merge(
    {
      cluster = {
        policy_key = var.egress_firewall.cluster_policy_key
        sources    = local.egress_cluster_sources
      }
    },
    {
      for key, attachment in var.egress_attachments : key => {
        policy_key = attachment.policy_key
        sources    = [local.additional_subnet_geometry[attachment.subnet_group_key].ipv4_cidr]
      }
    },
  ) : {}

  private_services_access_cidr = "${google_compute_global_address.private_services_access.address}/${google_compute_global_address.private_services_access.prefix_length}"

  # VPC-internal destinations, reached without inspection like VPC-local routes.
  egress_internal_destination_cidrs = concat(
    [var.subnet_cidr, var.pod_cidr, var.service_cidr, local.private_services_access_cidr],
    [for name in keys(local.active_subnet_groups) : local.additional_subnet_geometry[name].ipv4_cidr],
  )

  # Ranges that must stay disjoint, as [first, last] integer addresses.
  egress_layout_cidrs = merge(
    { subnet_cidr = var.subnet_cidr, pod_cidr = var.pod_cidr, service_cidr = var.service_cidr },
    length(var.additional_subnet_groups) > 0 ? { additional_subnet_groups_cidr = var.additional_subnet_groups_cidr } : {},
  )
  egress_layout_ranges = { for name, cidr in local.egress_layout_cidrs : name => [
    sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)]),
    sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)]),
  ] }
  egress_layout_overlaps = distinct(flatten([for name, range in local.egress_layout_ranges : [
    for other, other_range in local.egress_layout_ranges : join(" and ", sort([name, other]))
    if name != other && range[0] <= other_range[1] && other_range[0] <= range[1]
  ]]))
  # Keep assigned PSA checks separate so unknown allocation cannot defer checks
  # between caller-supplied ranges at plan time.
  egress_psa_range = [
    sum([for i, octet in split(".", cidrhost(local.private_services_access_cidr, 0)) : tonumber(octet) * pow(256, 3 - i)]),
    sum([for i, octet in split(".", cidrhost(local.private_services_access_cidr, -1)) : tonumber(octet) * pow(256, 3 - i)]),
  ]
  egress_psa_overlaps = [for name, range in local.egress_layout_ranges : name
    if range[0] <= local.egress_psa_range[1] && local.egress_psa_range[0] <= range[1]
  ]
  # Managed VPC ranges must be private and disjoint from public exceptions.
  egress_private_ranges = ["10.0.0.0/8", "100.64.0.0/10", "172.16.0.0/12", "192.168.0.0/16"]
  egress_non_private_cidrs = [for name, cidr in local.egress_layout_cidrs : "${name} ${cidr}" if !anytrue([
    for private in local.egress_private_ranges :
    tonumber(split("/", cidr)[1]) >= tonumber(split("/", private)[1]) && cidrsubnet("${cidrhost(cidr, 0)}/${split("/", private)[1]}", 0, 0) == private
  ])]
}

data "google_compute_zones" "egress" {
  count   = local.egress_firewall_enabled && length(var.zones) == 0 ? 1 : 0
  project = var.project_id
  region  = var.region
}

# Always present: range overlaps are rejected even with the firewall disabled.
resource "terraform_data" "network_layout_contract" {
  input = local.egress_firewall_enabled

  lifecycle {
    precondition {
      condition     = length(local.egress_layout_overlaps) == 0
      error_message = "Network ranges overlap: ${join("; ", local.egress_layout_overlaps)}. Choose disjoint subnet_cidr, pod_cidr, service_cidr, additional_subnet_groups_cidr and assigned Private Services Access range."
    }
    precondition {
      condition     = length(local.egress_psa_overlaps) == 0
      error_message = "Assigned Private Services Access range ${local.private_services_access_cidr} overlaps ${join(", ", local.egress_psa_overlaps)}. Choose disjoint workload ranges before provisioning."
    }
    precondition {
      condition     = !local.egress_firewall_enabled || length(local.egress_non_private_cidrs) == 0
      error_message = "Managed egress needs every VPC range inside RFC 1918 or 100.64.0.0/10 so internal traffic keeps normal routing; not private: ${join(", ", local.egress_non_private_cidrs)}."
    }
  }
}

# ----------------------------------------------------------------------------
# Additional subnet groups (independent of egress_firewall.enabled)
# ----------------------------------------------------------------------------

resource "terraform_data" "additional_subnet_contract" {
  count = length(var.additional_subnet_groups) > 0 ? 1 : 0
  input = length(var.additional_subnet_groups)

  lifecycle {
    precondition {
      condition     = local.additional_subnet_prefixes_valid
      error_message = "additional_subnet_groups ipv4_prefix_length must be an integer from /${local.additional_subnet_prefix} to /29 for the allocation range ${var.additional_subnet_groups_cidr}."
    }
    precondition {
      condition     = local.additional_subnet_fits
      error_message = "additional_subnet_groups do not fit in ${var.additional_subnet_groups_cidr}; sequential aligned requests include retired entries. Append smaller groups; existing allocations are never moved."
    }
    precondition {
      condition     = alltrue([for name in values(local.additional_subnet_names) : length(name) <= 63])
      error_message = "additional_subnet_groups subnet names (ext-<group>-<environment>) must be 63 characters or fewer; shorten the group name."
    }
  }
}

# One permanent allocation record per group, retired entries included. The
# postcondition rejects resizing, reordering, renaming or moving the range;
# prevent_destroy rejects removing an entry. Full teardown is in the module
# README.
resource "terraform_data" "additional_subnet_geometry" {
  for_each = local.additional_subnet_geometry
  input    = each.value

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [input]
    postcondition {
      condition     = jsonencode(self.output) == jsonencode(local.additional_subnet_geometry[each.key])
      error_message = "additional_subnet_groups[${each.key}] recorded allocation ${jsonencode(self.output)} differs from the calculated ${jsonencode(local.additional_subnet_geometry[each.key])}. Keep applied entries in their original order and size (retired tombstones included) and keep additional_subnet_groups_cidr unchanged; append a new group to migrate."
    }
  }

  depends_on = [terraform_data.additional_subnet_contract]
}

resource "google_compute_subnetwork" "additional_group" {
  for_each = local.active_subnet_groups

  name          = local.additional_subnet_names[each.key]
  description   = "Ryvn additional subnet group ${each.key}"
  project       = var.project_id
  region        = var.region
  network       = module.gcp-network.network_id
  ip_cidr_range = terraform_data.additional_subnet_geometry[each.key].output.ipv4_cidr
  # Google APIs follow inspected internet egress; no private API bypass.
  private_ip_google_access = false

  dynamic "log_config" {
    for_each = var.flow_logs.enable == "true" ? [var.flow_logs] : []
    content {
      aggregation_interval = log_config.value.interval
      flow_sampling        = tonumber(log_config.value.sampling)
      metadata             = log_config.value.metadata
      metadata_fields      = log_config.value.metadata == "CUSTOM_METADATA" ? log_config.value.metadata_fields : null
      filter_expr          = log_config.value.filter
    }
  }

  depends_on = [terraform_data.network_layout_contract]
}

# ----------------------------------------------------------------------------
# Native inspection and firewall policy
# ----------------------------------------------------------------------------

module "egress_firewall" {
  source = "./modules/egress-firewall"
  count  = local.egress_firewall_enabled ? 1 : 0

  name                       = var.environment
  project_id                 = var.project_id
  network_id                 = module.gcp-network.network_id
  zones                      = local.egress_zones
  internal_destination_cidrs = local.egress_internal_destination_cidrs
  classes                    = local.egress_classes
  policies                   = var.egress_firewall.policies
  platform_https_domains     = local.platform_https_domains

  depends_on = [
    terraform_data.network_layout_contract,
    google_compute_subnetwork.additional_group,
  ]
}

# ----------------------------------------------------------------------------
# Public outputs
# ----------------------------------------------------------------------------

output "egress_firewall" {
  description = "Native NGFW policy, source attachments, API readiness, limitations and log references. Web and exact tuples share the root Cloud NAT IPs. API readiness is not a traffic-validation token."
  value = {
    enabled            = local.egress_firewall_enabled
    default_action     = local.egress_firewall_enabled ? var.egress_firewall.default_action : null
    implementation     = local.egress_firewall_enabled ? "cloud-ngfw-enterprise-url-filtering" : null
    cluster_policy_key = local.egress_firewall_enabled ? var.egress_firewall.cluster_policy_key : null
    platform_baseline  = local.egress_firewall_enabled ? sort(tolist(local.platform_https_domains)) : []
    # Stable identity -> enforcing native rule and provenance for every permission.
    effective_rules = try(module.egress_firewall[0].effective_rules, {})
    attachments = local.egress_firewall_enabled ? { for key, attachment in var.egress_attachments : key => {
      schema_version   = 1
      provider         = "gcp"
      subnet_group_key = attachment.subnet_group_key
      policy_key       = attachment.policy_key
      project_id       = var.project_id
      region           = var.region
      network          = module.gcp-network.network_self_link
      subnetwork       = google_compute_subnetwork.additional_group[attachment.subnet_group_key].self_link
      ipv4_cidr        = local.additional_subnet_geometry[attachment.subnet_group_key].ipv4_cidr
    } } : {}
    nat_public_ips   = local.egress_firewall_enabled ? [google_compute_address.nat.address] : []
    web_egress_ips   = local.egress_firewall_enabled ? [google_compute_address.nat.address] : []
    readiness        = local.egress_firewall_enabled ? module.egress_firewall[0].readiness : null
    capabilities     = local.egress_firewall_enabled ? module.egress_firewall[0].capabilities : null
    enforcement_refs = local.egress_firewall_enabled ? module.egress_firewall[0].enforcement_refs : null
    compiled_policy  = local.egress_firewall_enabled ? module.egress_firewall[0].compiled_policy : null
    log_refs         = local.egress_firewall_enabled ? module.egress_firewall[0].log_refs : null
    exclusions       = local.egress_firewall_enabled ? module.egress_firewall[0].exclusions : []
    configured_scope = local.egress_firewall_enabled ? {
      cluster_sources       = local.egress_cluster_sources
      external_sources      = { for key, attachment in var.egress_attachments : key => local.additional_subnet_geometry[attachment.subnet_group_key].ipv4_cidr }
      internal_destinations = local.egress_internal_destination_cidrs
      web_ports             = { http = 80, https = 443 }
    } : null
  }

  depends_on = [
    module.egress_firewall,
    google_compute_router_nat.nat,
  ]
}

output "additional_subnet_groups" {
  description = "Active external network inventory keyed by group name: regional subnetwork, CIDR and prefix length. Independent of firewall membership; a group listed here is only protected once an egress_attachments entry assigns it and egress_firewall.attachments publishes it."
  value = { for name, group in local.active_subnet_groups : name => {
    ipv4_prefix_length = group.ipv4_prefix_length
    ipv4_cidr          = local.additional_subnet_geometry[name].ipv4_cidr
    region             = var.region
    subnetwork         = google_compute_subnetwork.additional_group[name].self_link
  } }
}

# Default node pool configurations
locals {
  default_node_pools = {
    system = {
      machine_type    = "e2-standard-2"
      total_min_count = 1
      total_max_count = 2
      # We set this to 0 to avoid over provisioning the cluster
      # otherwise, we end up with 6 nodes created since gcp will always
      # try to provision one node per zone
      initial_node_count = 0
      disk_size_gb       = 50
      disk_type          = "pd-standard"
    }
    application = {
      machine_type       = "e2-standard-4"
      total_min_count    = 2
      total_max_count    = 5
      initial_node_count = 1
      disk_size_gb       = 50
      disk_type          = "pd-standard"
    }
  }

  # Default node pool taints (matches AWS CriticalAddonsOnly taint and Azure only_critical_addons_enabled)
  default_node_pools_taints = {
    system = [
      {
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }
    ]
  }

  # Default node pool labels
  default_node_pools_labels = {
    all = {
      environment = var.environment
    }
    "system" = {
      "ryvn.app/node-group-name" = "system"
    }
    "application" = {
      "ryvn.app/node-group-name" = "application"
    }
  }

  # Merge user provided node pools with defaults, ensuring null values don't override defaults
  node_pools = {
    for name, config in merge(local.default_node_pools, var.node_pools) :
    name => merge(
      # Start with the default configuration for this node pool if it exists
      try(local.default_node_pools[name], {}),
      # Apply the user configuration, but only non-null values
      {
        for k, v in config : k => v if v != null
      }
    )
  }

  # Merge default labels with user-provided labels (nested merge)
  node_pools_labels = merge(
    local.default_node_pools_labels,
    {
      for pool_name, user_labels in var.node_pools_labels : pool_name => merge(
        try(local.default_node_pools_labels[pool_name], {}),
        user_labels
      )
    }
  )

  # Build node pool taints: default taints cannot be overridden, user taints only apply to non-system pools
  node_pools_taints = merge(
    local.default_node_pools_taints,
    {
      for pool_name, config in var.node_pools : pool_name => try(config.taints, [])
      if config.taints != null && !contains(keys(local.default_node_pools_taints), pool_name)
    }
  )
}

# GKE cluster
module "gke" {
  source = "terraform-google-modules/kubernetes-engine/google//modules/beta-private-cluster"
  # Exact pin: the dependency lock file does not cover modules, so this is what
  # makes the module version reproducible. Bumping a major is a reviewed change.
  version             = "45.0.0"
  project_id          = var.project_id
  name                = "ryvn-gke-${var.environment}"
  region              = var.region
  zones               = var.zones
  network             = module.gcp-network.network_name
  subnetwork          = module.gcp-network.subnets_names[0]
  ip_range_pods       = local.pods_range_name
  ip_range_services   = local.svc_range_name
  deletion_protection = var.deletion_protection

  # Private cluster configuration
  enable_private_nodes = true
  # The provider toggles this in place, so existing clusters pick it up on their next apply.
  enable_private_endpoint = true
  # Lets Ryvn bootstrap the agent during provisioning over the DNS-based endpoint, which is gated by IAM.
  # See https://cloud.google.com/kubernetes-engine/docs/concepts/network-isolation#dns-based_endpoint
  dns_allow_external_traffic = true

  # `DATAPATH_PROVIDER_UNSPECIFIED` is both our default and the upstream
  # module's, so an environment that does not set this stays unchanged.
  datapath_provider = var.datapath_provider
  # FQDN network policies require Dataplane V2; left unset otherwise so
  # kube-proxy clusters see no diff.
  enable_fqdn_network_policy = var.datapath_provider == "ADVANCED_DATAPATH" ? true : null

  # Secrets encryption, see kms.tf. DECRYPTED with no key is the module default, so opting out
  # changes nothing on an unencrypted cluster.
  database_encryption = [{
    state    = local.cluster_secrets_encrypted ? "ENCRYPTED" : "DECRYPTED"
    key_name = local.cluster_secrets_encrypted ? local.cluster_secrets_kms_key : ""
  }]

  # Already the default; set explicitly because Workload Identity requires it
  node_metadata = "GKE_METADATA"
  # Disable HTTP load balancing add-on since we're using NGINX Ingress
  http_load_balancing = false

  logging_enabled_components    = ["SYSTEM_COMPONENTS", "APISERVER", "CONTROLLER_MANAGER", "SCHEDULER"]
  monitoring_enabled_components = ["SYSTEM_COMPONENTS"]
  # Managed Service for Prometheus stays off; the collector scrapes workload metrics.
  monitoring_enable_managed_prometheus = false

  # Configure cluster RBAC
  cluster_resource_labels = {
    environment = var.environment
  }

  # Service account configuration
  create_service_account = true
  service_account_name   = var.cluster_service_account_name

  # Node pools configuration using merged defaults and user configs
  node_pools = [
    for name, config in local.node_pools : merge(
      {
        name                        = name
        auto_repair                 = true
        auto_upgrade                = true
        preemptible                 = false
        autoscaling                 = true
        enable_secure_boot          = true
        enable_integrity_monitoring = true
      },
      { for k, v in config : k => v if !contains(["taints", "labels"], k) }
    )
  ]

  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  node_pools_metadata = {
    all = {
      disable-legacy-endpoints = "true"
    }
  }

  node_pools_tags = {
    all         = [substr("gke-${var.environment}", 0, 63)]
    system      = ["gke-ryvn-system"]
    application = ["gke-ryvn-application"]
  }

  node_pools_labels = local.node_pools_labels
  node_pools_taints = local.node_pools_taints
}

# ============================================================================
# Ryvn agent and add-on service accounts
# ============================================================================

# The identity Terraform is running as. Cluster access for it is granted below
# so the same identity can bootstrap in-cluster resources after the apply.
data "google_client_openid_userinfo" "current" {}

locals {
  current_sa = data.google_client_openid_userinfo.current.email

  # Permissions for the in-cluster agent that provisions workload blueprints,
  # used unless terraform_executor_policies overrides them. Deliberately shaped
  # as management-without-data-access: instances and databases can be created,
  # resized and deleted, but no permission here reads object, row or log
  # contents.
  default_permissions = [
    "iam.roles.create",
    "iam.roles.delete",
    "iam.roles.get",
    "iam.roles.list",
    "iam.roles.update",
    "iam.serviceAccounts.create",
    "iam.serviceAccounts.delete",
    "iam.serviceAccounts.get",
    "iam.serviceAccounts.getIamPolicy",
    "iam.serviceAccounts.list",
    "iam.serviceAccounts.setIamPolicy",
    "iam.serviceAccounts.update",
    "resourcemanager.projects.getIamPolicy",
    "resourcemanager.projects.setIamPolicy",

    # Allow Cloud SQL instance creation and inspection (but not data access).
    # Mutations on existing instances live in local.cloudsql_managed_permissions.
    "cloudsql.instances.create",
    "cloudsql.instances.get",
    "cloudsql.instances.list",
    "cloudsql.databases.get",
    "cloudsql.databases.list",
    "cloudsql.users.get",
    "cloudsql.users.list",
    "cloudsql.backupRuns.get",
    "cloudsql.backupRuns.list",

    # Allow tagging freshly created Cloud SQL instances as Ryvn-managed. An
    # instance cannot carry the tag before it exists, so these stay unscoped.
    "cloudsql.instances.createTagBinding",
    "cloudsql.instances.deleteTagBinding",
    "cloudsql.instances.listTagBindings",
    "cloudsql.instances.listEffectiveTags",
    "resourcemanager.tagKeys.get",
    "resourcemanager.tagKeys.list",
    "resourcemanager.tagValues.get",
    "resourcemanager.tagValues.list",
    "resourcemanager.tagValueBindings.create",
    "resourcemanager.tagValueBindings.delete",

    # Allow Memorystore instance management, including fetching generated AUTH strings
    "redis.instances.create",
    "redis.instances.delete",
    "redis.instances.get",
    "redis.instances.getAuthString",
    "redis.instances.list",
    "redis.instances.update",
    "redis.instances.updateAuth",
    "redis.operations.get",
    "redis.operations.list",

    # Allow compute operations except sensitive ones
    "compute.addresses.create",
    "compute.addresses.delete",
    "compute.addresses.get",
    "compute.addresses.list",
    "compute.addresses.use",
    "compute.disks.create",
    "compute.disks.delete",
    "compute.disks.get",
    "compute.disks.list",
    "compute.disks.use",
    "compute.firewalls.create",
    "compute.firewalls.delete",
    "compute.firewalls.get",
    "compute.firewalls.list",
    "compute.firewalls.update",
    "compute.instances.create",
    "compute.instances.delete",
    "compute.instances.get",
    "compute.instances.list",
    "compute.instances.start",
    "compute.instances.stop",
    "compute.instances.use",
    "compute.networks.create",
    "compute.networks.delete",
    "compute.networks.get",
    "compute.networks.list",
    "compute.networks.use",
    "compute.subnetworks.create",
    "compute.subnetworks.delete",
    "compute.subnetworks.get",
    "compute.subnetworks.list",
    "compute.subnetworks.use",
    "compute.regions.get",
    "compute.regions.list",
    "compute.zones.get",
    "compute.zones.list",

    # Allow container (GKE) operations
    "container.clusters.create",
    "container.clusters.delete",
    "container.clusters.get",
    "container.clusters.list",
    "container.clusters.update",
    "container.operations.get",
    "container.operations.list",

    # Allow storage bucket operations (but not object access)
    "storage.buckets.create",
    "storage.buckets.delete",
    "storage.buckets.get",
    "storage.buckets.list",
    "storage.buckets.update",

    # Allow monitoring operations
    "monitoring.dashboards.get",
    "monitoring.dashboards.list",
    "monitoring.groups.get",
    "monitoring.groups.list",
    "monitoring.metricDescriptors.get",
    "monitoring.metricDescriptors.list",
    "monitoring.monitoredResourceDescriptors.get",
    "monitoring.monitoredResourceDescriptors.list",
    "monitoring.timeSeries.list",

    # Allow logging configuration (but not log access)
    "logging.sinks.create",
    "logging.sinks.delete",
    "logging.sinks.get",
    "logging.sinks.list",
    "logging.sinks.update",
    "logging.views.create",
    "logging.views.delete",
    "logging.views.get",
    "logging.views.list",
    "logging.views.update",

    # Allow Cloud Run operations
    "run.services.create",
    "run.services.delete",
    "run.services.get",
    "run.services.list",
    "run.services.update",

    # Allow service management
    "servicemanagement.services.get",
    "servicemanagement.services.list",
    "serviceusage.services.enable",
    "serviceusage.services.disable",
    "serviceusage.services.get",
    "serviceusage.services.list",

    # Allow load balancing operations
    "compute.backendServices.create",
    "compute.backendServices.delete",
    "compute.backendServices.get",
    "compute.backendServices.list",
    "compute.backendServices.use",
    "compute.urlMaps.create",
    "compute.urlMaps.delete",
    "compute.urlMaps.get",
    "compute.urlMaps.list",
    "compute.urlMaps.use",
    "compute.targetHttpProxies.create",
    "compute.targetHttpProxies.delete",
    "compute.targetHttpProxies.get",
    "compute.targetHttpProxies.list",
    "compute.targetHttpProxies.use",
    "compute.targetHttpsProxies.create",
    "compute.targetHttpsProxies.delete",
    "compute.targetHttpsProxies.get",
    "compute.targetHttpsProxies.list",
    "compute.targetHttpsProxies.use",
    "compute.sslCertificates.create",
    "compute.sslCertificates.delete",
    "compute.sslCertificates.get",
    "compute.sslCertificates.list",

    # Allow DNS operations
    "dns.changes.create",
    "dns.changes.get",
    "dns.changes.list",
    "dns.managedZones.create",
    "dns.managedZones.delete",
    "dns.managedZones.get",
    "dns.managedZones.list",
    "dns.managedZones.update",
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.get",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.update"
  ]

  # Cloud SQL mutations that can destroy or expose an existing database. When
  # local.scope_cloudsql is set these are granted through a separate role whose
  # binding only applies to instances carrying this environment's Ryvn-managed
  # tag, so the agent cannot touch Cloud SQL instances it did not create.
  cloudsql_managed_permissions = [
    "cloudsql.instances.delete",
    "cloudsql.instances.update",
    "cloudsql.databases.create",
    "cloudsql.databases.delete",
    "cloudsql.databases.update",
    "cloudsql.users.create",
    "cloudsql.users.delete",
    "cloudsql.users.update",
    "cloudsql.backupRuns.create",
    "cloudsql.backupRuns.delete",
  ]

  # A caller-supplied permission list replaces the defaults outright, including
  # the tag-scoped Cloud SQL role below.
  scope_cloudsql = length(var.terraform_executor_policies.permissions) == 0
}

# IAM member for cluster bootstrap
resource "google_project_iam_member" "cluster_admin" {
  count   = var.cluster_bootstrap_perms ? 1 : 0
  project = var.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${local.current_sa}"
}

# IAM member for container developer when not bootstrapping
resource "google_project_iam_member" "container_developer" {
  count   = var.cluster_bootstrap_perms ? 0 : 1
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${local.current_sa}"
}

# Random IDs for service accounts
resource "random_id" "ryvn_agent" {
  byte_length = 4
}

resource "random_id" "external_dns" {
  byte_length = 4
}

resource "random_id" "cert_manager" {
  byte_length = 4
}

# Create a GCP service account for ryvn-agent
resource "google_service_account" "ryvn_agent" {
  account_id   = "ryvn-agent-${random_id.ryvn_agent.hex}"
  display_name = "Ryvn Agent Service Account - ${var.environment}"
  project      = var.project_id
}

# Allow the Kubernetes ServiceAccount to impersonate the GCP ServiceAccount
resource "google_service_account_iam_binding" "ryvn_agent_workload_identity" {
  service_account_id = google_service_account.ryvn_agent.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.ryvn_system_namespace}/ryvn-agent]"
  ]

  # The PROJECT.svc.id.goog identity pool is registered by GCP only once the GKE
  # cluster is up. Without this dependency Terraform can apply the binding first
  # and fail with "Error 400: Identity Pool does not exist".
  depends_on = [module.gke]
}

# Grant necessary IAM permissions to the service account
resource "google_project_iam_custom_role" "ryvn_agent_role" {
  role_id     = "ryvn_agent_role_${replace(lower(var.environment), "-", "_")}"
  title       = "Ryvn Agent Role ${var.environment}"
  description = length(var.terraform_executor_policies.permissions) > 0 ? "Custom role for Ryvn Agent with specified permissions" : "Custom role for Ryvn Agent with broad permissions except sensitive data access"
  permissions = length(var.terraform_executor_policies.permissions) > 0 ? var.terraform_executor_policies.permissions : local.default_permissions
  project     = var.project_id
}

# Tag marking the Cloud SQL instances this environment's agent provisioned.
resource "google_tags_tag_key" "cloudsql_managed" {
  count = local.scope_cloudsql ? 1 : 0

  parent      = "projects/${var.project_id}"
  short_name  = "ryvn-managed-${replace(lower(var.environment), "_", "-")}"
  description = "Marks resources provisioned by the Ryvn agent in ${var.environment}"
}

resource "google_tags_tag_value" "cloudsql_managed" {
  count = local.scope_cloudsql ? 1 : 0

  parent      = google_tags_tag_key.cloudsql_managed[0].id
  short_name  = "true"
  description = "Provisioned by the Ryvn agent in ${var.environment}"
}

resource "google_project_iam_custom_role" "ryvn_agent_cloudsql_role" {
  count = local.scope_cloudsql ? 1 : 0

  role_id     = "ryvn_agent_cloudsql_role_${replace(lower(var.environment), "-", "_")}"
  title       = "Ryvn Agent Cloud SQL Role ${var.environment}"
  description = "Cloud SQL mutations for the Ryvn Agent, granted only on Ryvn-managed instances"
  permissions = local.cloudsql_managed_permissions
  project     = var.project_id
}

resource "google_project_iam_member" "ryvn_agent_cloudsql_role_binding" {
  count = local.scope_cloudsql ? 1 : 0

  project = var.project_id
  role    = google_project_iam_custom_role.ryvn_agent_cloudsql_role[0].id
  member  = "serviceAccount:${google_service_account.ryvn_agent.email}"

  condition {
    title       = "Ryvn-managed resources only"
    description = "Applies only to resources tagged ryvn-managed for ${var.environment}"
    expression  = "resource.matchTagId('${google_tags_tag_key.cloudsql_managed[0].id}', '${google_tags_tag_value.cloudsql_managed[0].id}')"
  }
}

output "cloudsql_managed_tag_value" {
  description = "Permanent ID of the tag value the Ryvn agent must attach to Cloud SQL instances it provisions. Empty when Cloud SQL permissions are not tag-scoped."
  value       = local.scope_cloudsql ? google_tags_tag_value.cloudsql_managed[0].id : ""
}

# Attach predefined roles if specified
resource "google_project_iam_member" "ryvn_agent_roles" {
  for_each = toset(var.terraform_executor_policies.roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.ryvn_agent.email}"
}

# Attach the custom role to the service account
resource "google_project_iam_binding" "ryvn_agent_role_binding" {
  project = var.project_id
  role    = google_project_iam_custom_role.ryvn_agent_role.id

  members = [
    "serviceAccount:${google_service_account.ryvn_agent.email}"
  ]
}

# Create a GCP service account for external-dns
resource "google_service_account" "external_dns" {
  account_id   = "ext-dns-${random_id.external_dns.hex}"
  display_name = "External DNS Service Account - ${var.environment}"
  project      = var.project_id

}

# Allow the Kubernetes ServiceAccount to impersonate the GCP ServiceAccount for external-dns
resource "google_service_account_iam_binding" "external_dns_workload_identity" {
  service_account_id = google_service_account.external_dns.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.external_dns_namespace}/external-dns]"
  ]

  # The PROJECT.svc.id.goog identity pool is registered by GCP only once the GKE
  # cluster is up. Without this dependency Terraform can apply the binding first
  # and fail with "Error 400: Identity Pool does not exist".
  depends_on = [module.gke]
}

# Grant DNS Admin role to the external-dns service account
resource "google_project_iam_member" "external_dns_dns_admin" {
  project = var.project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.external_dns.email}"
}

resource "google_service_account" "cert_manager" {
  account_id   = "cert-mgr-${random_id.cert_manager.hex}"
  display_name = "Cert Manager Service Account - ${var.environment}"
  project      = var.project_id
}

resource "google_service_account_iam_binding" "cert_manager_workload_identity" {
  service_account_id = google_service_account.cert_manager.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.cert_manager_namespace}/cert-manager]"
  ]

  # The PROJECT.svc.id.goog identity pool is registered by GCP only once the GKE
  # cluster is up. Without this dependency Terraform can apply the binding first
  # and fail with "Error 400: Identity Pool does not exist".
  depends_on = [module.gke]
}

resource "google_project_iam_member" "cert_manager_dns_admin" {
  project = var.project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.cert_manager.email}"
}

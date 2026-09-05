data "azurerm_client_config" "current" {}

locals {
  cluster_name                  = "aks-${var.environment_name}"
  aks_managed_outbound_ip_count = 1
  use_udr_egress                = var.existing_route_table_id != null
  tags = merge({
    Environment = var.environment_name
    Terraform   = "true"
    Cluster     = local.cluster_name
  }, var.tags)

  # Azure auto-generates the node resource group as "MC_<rg>_<cluster>_<location>",
  # which can exceed Azure's 80-char limit on long environment names. When it would
  # overflow, set our own short name; otherwise leave null so existing clusters keep
  # the MC_* names already in their state and avoid a ForceNew replacement.
  azure_default_node_rg    = "MC_ryvn-rg-${var.environment_name}_${var.environment_name}-aks_${var.location}"
  node_resource_group_name = length(local.azure_default_node_rg) > 80 ? "ryvn-nrg-${var.environment_name}" : null

  # Define default node pools similar to EKS
  default_node_pools = {
    application = {
      name                 = "app"
      vm_size              = "Standard_D2als_v6" # AMD-based equivalent to t3.medium
      node_count           = 2                   # One per AZ
      max_count            = 4                   # Max two per AZ
      min_count            = 2                   # Min one per AZ
      os_disk_size_gb      = 50
      max_pods             = 100
      auto_scaling_enabled = true
      node_labels = {
        "ryvn.app/node-group-name" = "application"
      }
      # Azure defaults these server-side; setting them explicitly keeps plans
      # empty when nothing has changed.
      upgrade_settings = {
        max_surge                     = "10%"
        drain_timeout_in_minutes      = 30
        node_soak_duration_in_minutes = 5
      }
    }
    system = {
      name                 = "system"
      vm_size              = "Standard_D2as_v6" # AMD-based equivalent
      node_count           = 1                  # One per AZ
      max_count            = 3                  # Max two per AZ
      min_count            = 1                  # Min one per AZ
      os_disk_size_gb      = 50
      max_pods             = 100
      auto_scaling_enabled = true
      node_labels = {
        "ryvn.app/node-group-name" = "system"
      }
    }
  }

  # Baseline applied to every pool (named or custom) so user-defined pools
  # don't inherit provider defaults that conflict with min_count/max_count.
  node_pool_baseline = {
    auto_scaling_enabled = true
    os_disk_size_gb      = 50
    max_pods             = 100
  }

  # Merge the user provided node pools with defaults, ensuring null values don't override defaults
  merged_node_pools = {
    for name, config in merge(local.default_node_pools, var.aks_node_pools) :
    name => merge(
      # Baseline for pools that aren't in default_node_pools (e.g. custom pools)
      local.node_pool_baseline,
      # Start with the default configuration for this node group if it exists
      try(local.default_node_pools[name], {}),
      # Apply the user configuration, but only non-null values
      {
        for k, v in config : k => v if v != null
      },
      # Always ensure name, labels, and taints are set correctly
      {
        name = substr(coalesce(try(var.aks_node_pools[name].name, null), try(local.default_node_pools[name].name, null), name), 0, 8)
        node_labels = merge(
          try(local.default_node_pools[name].node_labels, {}),
          try(var.aks_node_pools[name].labels, {}),
          { "ryvn.app/node-group-name" = name }
        )
        node_taints = try(var.aks_node_pools[name].taints, [])
      }
    )
  }

  # Assign subnets to node pools
  # - application: private-2
  # - system: private-1
  # - custom pools: distributed across private-1, private-2, private-3 using hash
  node_pool_subnets = {
    for name in keys(local.merged_node_pools) :
    name => name == "application" ? "private-2" : (
      name == "system" ? "private-1" : (
        "private-${(parseint(substr(md5(name), 0, 1), 16) % 3) + 1}"
      )
    )
  }
}

module "aks" {
  source  = "Azure/aks/azurerm"
  version = "~> 11.0"

  prefix                    = var.environment_name
  node_resource_group       = local.node_resource_group_name
  resource_group_name       = azurerm_resource_group.rg.name
  location                  = var.location
  kubernetes_version        = var.cluster_version
  automatic_channel_upgrade = "patch"
  agents_availability_zones = length(local.azs) > 0 ? local.azs : null

  # Default node pool configuration (system nodes)
  agents_count                = local.merged_node_pools.system.node_count
  agents_max_count            = local.merged_node_pools.system.max_count
  agents_max_pods             = local.merged_node_pools.system.max_pods
  agents_min_count            = local.merged_node_pools.system.min_count
  agents_pool_name            = local.merged_node_pools.system.name
  agents_size                 = local.merged_node_pools.system.vm_size
  agents_labels               = local.merged_node_pools.system.node_labels
  temporary_name_for_rotation = "tmpsystem"
  agents_pool_linux_os_configs = [
    {
      transparent_huge_page_enabled = "always"
      sysctl_configs = [
        {
          fs_aio_max_nr               = 65536
          fs_file_max                 = 100000
          fs_inotify_max_user_watches = 1000000
        }
      ]
    }
  ]
  agents_type                        = "VirtualMachineScaleSets"
  azure_policy_enabled               = true
  cost_analysis_enabled              = var.cost_analysis_enabled
  key_vault_secrets_provider_enabled = var.key_vault_secrets_provider_enabled
  auto_scaling_enabled               = true
  host_encryption_enabled            = false
  os_disk_size_gb                    = local.merged_node_pools.system.os_disk_size_gb

  # Taint system nodes to only schedule critical addons (matches AWS CriticalAddonsOnly taint)
  only_critical_addons_enabled = true

  # Network configuration
  local_account_disabled                          = false
  log_analytics_workspace_enabled                 = false
  net_profile_dns_service_ip                      = local.dns_service_ip
  net_profile_service_cidr                        = local.service_cidr
  network_plugin                                  = "azure"
  network_plugin_mode                             = var.network_plugin_mode == "overlay" ? "overlay" : null
  net_profile_pod_cidr                            = var.network_plugin_mode == "overlay" ? var.pod_cidr : null
  network_policy                                  = "azure"
  load_balancer_profile_enabled                   = !local.use_udr_egress
  load_balancer_profile_managed_outbound_ip_count = local.use_udr_egress ? null : local.aks_managed_outbound_ip_count
  net_profile_outbound_type                       = local.use_udr_egress ? "userDefinedRouting" : "loadBalancer"
  private_cluster_enabled                         = false

  # Enable workload identity
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # RBAC and security
  rbac_aad_azure_rbac_enabled       = true
  rbac_aad_tenant_id                = data.azurerm_client_config.current.tenant_id
  role_based_access_control_enabled = true
  sku_tier                          = "Standard"
  vnet_subnet = {
    id = local.resolved_node_pool_subnet_ids["private-1"] # System nodes in private-1
  }

  # Additional node pools
  node_pools = {
    for name, config in local.merged_node_pools :
    name => merge(config, {
      vnet_subnet                 = { id = local.resolved_node_pool_subnet_ids[local.node_pool_subnets[name]] }
      zones                       = length(local.azs) > 0 ? local.azs : null # Spread across all AZs
      temporary_name_for_rotation = "tmp${config.name}"
    })
    if name != "system" # Skip system pool as it's configured above
  }

  tags = local.tags

  depends_on = [
    azurerm_virtual_network.main,
    azurerm_subnet.existing_vnet_node_pool,
    azurerm_subnet.existing_vnet_appgw,
    azurerm_subnet.existing_vnet_privatelink,
    azurerm_subnet_route_table_association.node_pool,
    azurerm_user_assigned_identity.ryvn_agent
  ]
}

# Grant cluster admin permissions to the terraform executor if bootstrap perms are enabled
resource "azurerm_role_assignment" "cluster_admin" {
  count                = var.cluster_bootstrap_perms ? 1 : 0
  principal_id         = data.azurerm_client_config.current.object_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  scope                = module.aks.aks_id

  depends_on = [
    module.aks
  ]
}

# Grant view-only permissions to the terraform executor if bootstrap perms are disabled
resource "azurerm_role_assignment" "cluster_viewer" {
  count                = var.cluster_bootstrap_perms ? 0 : 1
  principal_id         = data.azurerm_client_config.current.object_id
  role_definition_name = "Azure Kubernetes Service RBAC Reader"
  scope                = module.aks.aks_id

  depends_on = [
    module.aks
  ]
}

# Grant Network Contributor role to AKS control plane managed identity for Intneral Load Balancer management
# See note here: https://learn.microsoft.com/en-us/azure/aks/internal-lb?tabs=set-service-annotations#use-private-networks
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = local.resolved_vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = module.aks.cluster_identity.principal_id

  depends_on = [
    module.aks
  ]
}

# Grant Network Contributor on the caller-supplied route table when UDR egress is
# enabled. Required by AKS so the control plane can read the route table during
# cluster operations; the role assignment on the VNet does not extend to a route
# table that may live in a different resource group.
# https://learn.microsoft.com/en-us/azure/aks/egress-outboundtype
resource "azurerm_role_assignment" "aks_route_table_contributor" {
  count                = local.use_udr_egress ? 1 : 0
  scope                = var.existing_route_table_id
  role_definition_name = "Network Contributor"
  principal_id         = module.aks.cluster_identity.principal_id

  depends_on = [
    module.aks
  ]
}

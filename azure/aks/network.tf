locals {
  # ============================================================================
  # Existing VNet Configuration
  # ============================================================================
  use_existing_vnet = var.existing_vnet_id != null

  # ============================================================================
  # VNet Address Space Configuration
  # ============================================================================
  # Calculate Kubernetes service CIDR by incrementing second octet by 2
  # This creates a separate address space for ClusterIP services (not pods!)
  base_octets       = split(".", var.vnet_cidr)[0]
  second_octet      = tonumber(split(".", var.vnet_cidr)[1])
  k8s_services_cidr = "${local.base_octets}.${local.second_octet + 2}.0.0/16"

  address_spaces = [var.vnet_cidr]

  # ============================================================================
  # VNet Size Detection
  # ============================================================================
  vnet_prefix_length = tonumber(split("/", var.vnet_cidr)[1])
  vnet_total_ips     = pow(2, 32 - local.vnet_prefix_length)

  # Classify VNet size for appropriate subnet allocation
  vnet_size_class = (
    local.vnet_prefix_length >= 22 ? "compact" :  # /22-/24: 256-1024 IPs
    local.vnet_prefix_length >= 19 ? "standard" : # /19-/21: 2K-8K IPs
    "large"                                       # /16-/18: 16K-64K IPs
  )

  # ============================================================================
  # Mode-Aware Subnet Allocation Strategy
  # ============================================================================
  # Different strategies based on CNI mode and VNet size:
  #
  # OVERLAY MODE (nodes: 1 IP each, pods: separate CIDR)
  #   - Nodes need minimal IPs (1 per node, /24 = 251 nodes)
  #   - Infrastructure needs fixed ~64-128 IPs regardless of cluster size
  #   - Strategy: Reserve small fixed space for infra, maximize node capacity
  #
  # FLAT MODE (nodes + pods share VNet IPs)
  #   - Nodes need many IPs (~100 per node if max_pods=100)
  #   - Infrastructure needs ~64-128 IPs
  #   - Strategy: Allocate generously to nodes, moderate to infrastructure

  is_overlay_mode = var.network_plugin_mode == "overlay"

  # ============================================================================
  # Subnet Layout - Mode-Aware Design
  # ============================================================================

  # --- OVERLAY MODE: Maximize node capacity, minimize infrastructure ---
  # Reserve fixed space at end of VNet for infrastructure (overlay mode)
  # For /23 VNet: Reserve last /25 (128 IPs) for infrastructure
  # For /20 VNet: Reserve last /22 (1024 IPs) for infrastructure
  # For /16 VNet: Reserve last /17 (32K IPs) for infrastructure (backwards compat)
  overlay_infra_newbits = 1 # Always split in half to match current behavior
  overlay_node_cidr     = cidrsubnet(var.vnet_cidr, local.overlay_infra_newbits, 0)
  overlay_infra_cidr    = cidrsubnet(var.vnet_cidr, local.overlay_infra_newbits, 1)

  # Node pool subnets for overlay mode
  # Divide node space into 3 equal subnets for availability zones
  overlay_node_pool_cidrs = [
    cidrsubnet(local.overlay_node_cidr, 2, 0), # First third
    cidrsubnet(local.overlay_node_cidr, 2, 1), # Second third
    cidrsubnet(local.overlay_node_cidr, 2, 2), # Third third
  ]

  # Infrastructure subnets for overlay mode
  # Size based on VNet class
  overlay_infra_subnet_newbits = local.vnet_size_class == "compact" ? 2 : (local.vnet_size_class == "standard" ? 4 : 7)
  overlay_infra_cidrs = [
    cidrsubnet(local.overlay_infra_cidr, local.overlay_infra_subnet_newbits, 0), # App Gateway
    cidrsubnet(local.overlay_infra_cidr, local.overlay_infra_subnet_newbits, 1), # Private Endpoints
  ]

  # --- FLAT MODE: Use original subnet calculation for backwards compatibility ---
  flat_node_cidr  = cidrsubnet(var.vnet_cidr, 1, 0) # First half for nodes (private_vpc_cidr)
  flat_infra_cidr = cidrsubnet(var.vnet_cidr, 1, 1) # Second half for infrastructure (public_vpc_cidr)

  # Node pool subnets for flat mode - original calculation method
  # Divides first half into 16 parts (newbits=4), uses first 3
  flat_node_pool_cidrs = [
    cidrsubnet(local.flat_node_cidr, 4, 0), # Original: cidrsubnet(private_vpc_cidr, 4, 0)
    cidrsubnet(local.flat_node_cidr, 4, 1), # Original: cidrsubnet(private_vpc_cidr, 4, 1)
    cidrsubnet(local.flat_node_cidr, 4, 2), # Original: cidrsubnet(private_vpc_cidr, 4, 2)
  ]

  # Infrastructure subnets for flat mode
  flat_infra_subnet_newbits = local.vnet_size_class == "compact" ? 2 : (local.vnet_size_class == "standard" ? 4 : 7)
  flat_infra_cidrs = [
    cidrsubnet(local.flat_infra_cidr, local.flat_infra_subnet_newbits, 0), # App Gateway
    cidrsubnet(local.flat_infra_cidr, local.flat_infra_subnet_newbits, 1), # Private Endpoints
  ]

  # --- Select subnet allocation based on mode ---
  node_pool_subnet_cidrs = local.is_overlay_mode ? local.overlay_node_pool_cidrs : local.flat_node_pool_cidrs
  node_pool_subnet_names = ["private-1", "private-2", "private-3"]

  infrastructure_cidr           = local.is_overlay_mode ? local.overlay_infra_cidr : local.flat_infra_cidr
  infrastructure_subnet_newbits = local.is_overlay_mode ? local.overlay_infra_subnet_newbits : local.flat_infra_subnet_newbits
  infrastructure_subnet_cidrs   = local.is_overlay_mode ? local.overlay_infra_cidrs : local.flat_infra_cidrs
  infrastructure_subnet_names = [
    "appgw-subnet",       # For Azure Application Gateway ingress
    "privatelink-subnet", # For Private Endpoints (ACR, Key Vault, Storage, etc.)
  ]
  service_subnet_pool_cidr = cidrsubnet(local.infrastructure_cidr, local.infrastructure_subnet_newbits, length(local.infrastructure_subnet_names))
  postgres_subnet_cidr     = cidrsubnet(local.infrastructure_cidr, local.infrastructure_subnet_newbits, length(local.infrastructure_subnet_names) + 1)

  # --- Combined Subnet Configuration ---
  subnet_cidrs = concat(local.node_pool_subnet_cidrs, local.infrastructure_subnet_cidrs)
  subnet_names = concat(local.node_pool_subnet_names, local.infrastructure_subnet_names)

  # Sorted subnet names for consistent ordering in outputs
  sorted_subnet_names = sort(local.subnet_names)

  # ============================================================================
  # Kubernetes Service Network Configuration
  # ============================================================================
  # Kubernetes ClusterIP services CIDR (NOT for pods!)
  # This is from the separate address space (10.2.0.0/16)
  service_cidr   = cidrsubnet(local.k8s_services_cidr, 8, 1) # e.g., 10.2.1.0/24
  dns_service_ip = cidrhost(local.service_cidr, 10)          # e.g., 10.2.1.10
}

# ============================================================================
# Existing VNet Data Source & Validation
# ============================================================================

data "azurerm_virtual_network" "existing" {
  count               = local.use_existing_vnet ? 1 : 0
  name                = split("/", var.existing_vnet_id)[8]
  resource_group_name = split("/", var.existing_vnet_id)[4]
}

# ============================================================================
# VNet Resolution Locals
# ============================================================================

locals {
  resolved_vnet_id   = local.use_existing_vnet ? data.azurerm_virtual_network.existing[0].id : azurerm_virtual_network.main[0].id
  resolved_vnet_name = local.use_existing_vnet ? data.azurerm_virtual_network.existing[0].name : azurerm_virtual_network.main[0].name
  resolved_vnet_rg   = local.use_existing_vnet ? data.azurerm_virtual_network.existing[0].resource_group_name : azurerm_resource_group.rg.name

  # Subnet ID resolution: pick from existing VNet subnet resources or directly created subnets
  resolved_node_pool_subnet_ids = {
    for idx, name in local.node_pool_subnet_names : name => (
      local.use_existing_vnet
      ? azurerm_subnet.existing_vnet_node_pool[idx].id
      : azurerm_subnet.main[name].id
    )
  }
  resolved_appgw_subnet_id = (
    local.use_existing_vnet
    ? azurerm_subnet.existing_vnet_appgw[0].id
    : azurerm_subnet.main["appgw-subnet"].id
  )
  resolved_privatelink_subnet_id = (
    local.use_existing_vnet
    ? azurerm_subnet.existing_vnet_privatelink[0].id
    : azurerm_subnet.main["privatelink-subnet"].id
  )

  # Flat list of all resolved subnet IDs in alphabetical order
  resolved_subnet_ids = local.use_existing_vnet ? [
    for name in local.sorted_subnet_names : (
      contains(local.node_pool_subnet_names, name)
      ? azurerm_subnet.existing_vnet_node_pool[index(local.node_pool_subnet_names, name)].id
      : name == "appgw-subnet" ? azurerm_subnet.existing_vnet_appgw[0].id
      : azurerm_subnet.existing_vnet_privatelink[0].id
    )
  ] : [for name in local.sorted_subnet_names : azurerm_subnet.main[name].id]
}

# ============================================================================
# Ryvn-Created VNet (default path)
# ============================================================================

# State migration: the old Azure/network/azurerm module is incompatible with
# azurerm v4 (hard-pinned to < 4.0). These moved blocks migrate existing state
# from the module's internal resources to the direct resources below.
#
# Retain the original module.network → module.network[0] move so that
# deployments which never applied the intermediate version still chain
# correctly (module.network → module.network[0] → direct resources).
moved {
  from = module.network
  to   = module.network[0]
}
moved {
  from = module.network[0].azurerm_virtual_network.vnet
  to   = azurerm_virtual_network.main[0]
}
moved {
  from = module.network[0].azurerm_subnet.subnet_for_each["private-1"]
  to   = azurerm_subnet.main["private-1"]
}
moved {
  from = module.network[0].azurerm_subnet.subnet_for_each["private-2"]
  to   = azurerm_subnet.main["private-2"]
}
moved {
  from = module.network[0].azurerm_subnet.subnet_for_each["private-3"]
  to   = azurerm_subnet.main["private-3"]
}
moved {
  from = module.network[0].azurerm_subnet.subnet_for_each["appgw-subnet"]
  to   = azurerm_subnet.main["appgw-subnet"]
}
moved {
  from = module.network[0].azurerm_subnet.subnet_for_each["privatelink-subnet"]
  to   = azurerm_subnet.main["privatelink-subnet"]
}

resource "azurerm_virtual_network" "main" {
  count               = local.use_existing_vnet ? 0 : 1
  name                = "vnet-${var.environment_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = local.address_spaces
  tags                = local.tags

  depends_on = [azurerm_resource_group.rg]
}

resource "azurerm_subnet" "main" {
  for_each = local.use_existing_vnet ? {} : {
    for idx, name in local.subnet_names : name => {
      address_prefixes = [local.subnet_cidrs[idx]]
      service_endpoints = contains(local.node_pool_subnet_names, name) ? [
        "Microsoft.Storage",
        "Microsoft.ContainerRegistry",
        "Microsoft.Sql",
        "Microsoft.KeyVault"
      ] : []
      private_endpoint_network_policies = name == "privatelink-subnet" ? "Disabled" : "Enabled"
    }
  }

  name                              = each.key
  virtual_network_name              = azurerm_virtual_network.main[0].name
  resource_group_name               = azurerm_resource_group.rg.name
  address_prefixes                  = each.value.address_prefixes
  service_endpoints                 = each.value.service_endpoints
  private_endpoint_network_policies = each.value.private_endpoint_network_policies
}

# ============================================================================
# Existing VNet Subnets (created inside the caller-provided VNet)
# ============================================================================

resource "azurerm_subnet" "existing_vnet_node_pool" {
  count                = local.use_existing_vnet ? length(local.node_pool_subnet_names) : 0
  name                 = local.node_pool_subnet_names[count.index]
  virtual_network_name = data.azurerm_virtual_network.existing[0].name
  resource_group_name  = data.azurerm_virtual_network.existing[0].resource_group_name
  address_prefixes     = [local.node_pool_subnet_cidrs[count.index]]
  service_endpoints    = ["Microsoft.Storage", "Microsoft.ContainerRegistry", "Microsoft.Sql", "Microsoft.KeyVault"]

  private_endpoint_network_policies = "Enabled"

  lifecycle {
    precondition {
      condition = anytrue([
        for space in data.azurerm_virtual_network.existing[0].address_space :
        cidrhost("${cidrhost(var.vnet_cidr, 0)}/${tonumber(split("/", space)[1])}", 0) == cidrhost(space, 0)
        && tonumber(split("/", var.vnet_cidr)[1]) >= tonumber(split("/", space)[1])
      ])
      error_message = "vnet_cidr (${var.vnet_cidr}) must fall within one of the existing VNet's address spaces: ${join(", ", data.azurerm_virtual_network.existing[0].address_space)}."
    }
    precondition {
      condition     = local.second_octet <= 253
      error_message = "The effective VNet CIDR (${var.vnet_cidr}) has second octet ${local.second_octet}, but the Kubernetes service CIDR calculation requires second_octet <= 253 (it adds 2 to derive a non-overlapping service range). Use a VNet address space with a smaller second octet."
    }
    precondition {
      condition     = local.vnet_prefix_length <= (local.is_overlay_mode ? 24 : 22)
      error_message = "Subnet CIDR must be at least /${local.is_overlay_mode ? "24" : "22"} for ${var.network_plugin_mode} mode. Got /${local.vnet_prefix_length}."
    }
    precondition {
      condition     = lower(replace(data.azurerm_virtual_network.existing[0].location, " ", "")) == lower(replace(var.location, " ", ""))
      error_message = "Existing VNet location (${data.azurerm_virtual_network.existing[0].location}) must match deployment location (${var.location})."
    }
    precondition {
      condition     = cidrhost("${cidrhost(local.k8s_services_cidr, 0)}/${local.vnet_prefix_length}", 0) != cidrhost(var.vnet_cidr, 0)
      error_message = "Calculated Kubernetes service CIDR (${local.k8s_services_cidr}) overlaps with VNet CIDR (${var.vnet_cidr}). Use a VNet with a different address space."
    }
  }
}

resource "azurerm_subnet" "existing_vnet_appgw" {
  count                = local.use_existing_vnet ? 1 : 0
  name                 = "appgw-subnet"
  virtual_network_name = data.azurerm_virtual_network.existing[0].name
  resource_group_name  = data.azurerm_virtual_network.existing[0].resource_group_name
  address_prefixes     = [local.infrastructure_subnet_cidrs[0]]

  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_subnet" "existing_vnet_privatelink" {
  count                = local.use_existing_vnet ? 1 : 0
  name                 = "privatelink-subnet"
  virtual_network_name = data.azurerm_virtual_network.existing[0].name
  resource_group_name  = data.azurerm_virtual_network.existing[0].resource_group_name
  address_prefixes     = [local.infrastructure_subnet_cidrs[1]]

  private_endpoint_network_policies = "Disabled"
}

# ============================================================================
# Node Pool Subnet → Route Table Association (UDR egress)
# ============================================================================
# When existing_route_table_id is set, all node pool subnets are associated
# with the caller-provided route table so node egress traffic is steered to
# its network virtual appliance (NVA) per its 0.0.0.0/0 route. The
# AKS cluster must also have outbound_type=userDefinedRouting (see aks.tf).
#
# Scope is intentionally limited to node pool subnets:
# - appgw-subnet: Application Gateway v2 does not support 0.0.0.0/0 routes via
#   an NVA — required management traffic must reach the Azure backbone directly.
#   https://learn.microsoft.com/en-us/azure/application-gateway/configuration-infrastructure#supported-user-defined-routes
# - postgres-subnet: delegated to Microsoft.DBforPostgreSQL/flexibleServers; the
#   PaaS service manages its own egress, so UDRs do not apply.
# - privatelink-subnet: hosts inbound private endpoints, no outbound flows that
#   would benefit from UDR.

resource "azurerm_subnet_route_table_association" "node_pool" {
  for_each = var.existing_route_table_id != null ? toset(local.node_pool_subnet_names) : toset([])

  subnet_id      = local.resolved_node_pool_subnet_ids[each.value]
  route_table_id = var.existing_route_table_id
}

# ============================================================================
# Postgres Subnet (created in either VNet)
# ============================================================================

resource "azurerm_subnet" "postgres" {
  name                 = "postgres-subnet"
  virtual_network_name = local.resolved_vnet_name
  resource_group_name  = local.resolved_vnet_rg
  address_prefixes     = [local.postgres_subnet_cidr]
  service_endpoints    = ["Microsoft.Storage"]

  private_endpoint_network_policies = "Enabled"

  delegation {
    name = "postgres-flexible"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"

      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

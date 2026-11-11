output "application_gateway_network" {
  description = "Configured AppGW and planned backend contract for the external Helm gateway and DNS operator. enabled is infrastructure configuration, not backend health. AKS allocates the IP at runtime."
  value = merge(local.application_gateway_network, {
    enabled = local.ingress_frontend_enabled
    gateway = module.application_gateway.application_gateway
  })
}

output "ryvn_agent_role" {
  value = {
    id           = azurerm_user_assigned_identity.ryvn_agent.id
    tenant_id    = azurerm_user_assigned_identity.ryvn_agent.tenant_id
    client_id    = azurerm_user_assigned_identity.ryvn_agent.client_id
    principal_id = azurerm_user_assigned_identity.ryvn_agent.principal_id
  }
  description = "A map of ryvn_agent attributes: id, tenant_id, client_id, principal_id."
}

output "public_domain" {
  value = {
    nameservers = azurerm_dns_zone.public.name_servers
    name        = azurerm_dns_zone.public.name
    id          = azurerm_dns_zone.public.id
  }
  description = "A map of public domain attributes: nameservers, name, id."
}

output "internal_domain" {
  value = {
    nameservers = []
    name        = azurerm_private_dns_zone.internal.name
    id          = azurerm_private_dns_zone.internal.id
  }
  description = "A map of internal domain attributes: nameservers, name, id."
}

output "subscription" {
  value = {
    "subscription_id" = data.azurerm_client_config.current.subscription_id
    "client_id"       = data.azurerm_client_config.current.client_id
  }
  description = "A map of Azure subscription attributes: subscription_id, client_id."
}

output "resource_group" {
  value = {
    "name"     = azurerm_resource_group.rg.name
    "location" = var.location
  }
  description = "A map of Azure resource group attributes: name, location."
}

output "cluster" {
  sensitive = true
  value = {
    "id"                     = module.aks.aks_id
    "name"                   = module.aks.aks_name
    "cluster_ca_certificate" = module.aks.cluster_ca_certificate
    "cluster_fqdn"           = module.aks.cluster_fqdn
    "oidc_issuer_url"        = module.aks.oidc_issuer_url
    "location"               = module.aks.location
  }
  description = "A map of AKS cluster attributes: id, name, cluster_ca_certificate, cluster_fqdn, oidc_issuer_url, location. Local accounts are disabled, so no static kubeconfig or client certificate is exported; clients authenticate with Entra tokens."
}

output "cluster_oidc_issuer_url" {
  description = "Public OIDC issuer URL for Kubernetes service account tokens"
  value       = module.aks.oidc_issuer_url
}

output "external_dns_identity" {
  value = {
    client_id    = azurerm_user_assigned_identity.external_dns.client_id
    principal_id = azurerm_user_assigned_identity.external_dns.principal_id
    id           = azurerm_user_assigned_identity.external_dns.id
    tenant_id    = azurerm_user_assigned_identity.external_dns.tenant_id
  }
  description = "The managed identity used by ExternalDNS for public zones"
}

output "external_dns_private_identity" {
  value = {
    client_id    = azurerm_user_assigned_identity.external_dns_private.client_id
    principal_id = azurerm_user_assigned_identity.external_dns_private.principal_id
    id           = azurerm_user_assigned_identity.external_dns_private.id
    tenant_id    = azurerm_user_assigned_identity.external_dns_private.tenant_id
  }
  description = "The managed identity used by ExternalDNS for private zones"
}

output "cert_manager_identity" {
  value = {
    client_id    = azurerm_user_assigned_identity.cert_manager.client_id
    principal_id = azurerm_user_assigned_identity.cert_manager.principal_id
    id           = azurerm_user_assigned_identity.cert_manager.id
    tenant_id    = azurerm_user_assigned_identity.cert_manager.tenant_id
  }
  description = "The managed identity used by cert-manager"
}

# AKS creates its managed outbound public IPs in the node resource group with an
# auto-generated name and tags them aks-managed-type=aks-slb-managed-outbound-ip.
# Listing the node resource group (instead of indexing the cluster's
# effective_outbound_ips) keeps the lookup valid across an outbound-type change:
# the prior state's UDR profile has no outbound IPs yet, and the list runs after
# the cluster update because of depends_on.
data "azapi_resource_list" "aks_node_rg_public_ips" {
  # No managed outbound IPs exist when outbound type is userDefinedRouting; egress
  # source IP is whatever the network virtual appliance NATs to.
  count = local.use_udr_egress ? 0 : 1

  type                   = "Microsoft.Network/publicIPAddresses@2023-09-01"
  parent_id              = module.aks.node_resource_group_id
  response_export_values = ["value"]

  depends_on = [module.aks]
}

locals {
  aks_slb_managed_outbound_ip_tag = "aks-slb-managed-outbound-ip"
  aks_outbound_public_ips = var.egress_firewall.enabled ? module.egress_firewall[0].public_ip_addresses : compact([
    for public_ip in try(one(data.azapi_resource_list.aks_node_rg_public_ips).output.value, []) :
    try(public_ip.properties.ipAddress, "")
    if try(public_ip.tags["aks-managed-type"], "") == local.aks_slb_managed_outbound_ip_tag
  ])
}

output "vnet" {
  description = "A map of vnet attributes including network details and subnets"
  value = {
    # Core VNet information
    name          = local.resolved_vnet_name
    id            = local.resolved_vnet_id
    location      = local.use_existing_vnet ? data.azurerm_virtual_network.existing[0].location : azurerm_virtual_network.main[0].location
    existing_vnet = local.use_existing_vnet

    # CIDR information
    cidr                     = var.vnet_cidr
    address_spaces           = local.address_spaces
    service_subnet_pool_cidr = local.service_subnet_pool_cidr

    # Network mode configuration
    network_plugin_mode               = var.network_plugin_mode
    pod_cidr                          = var.network_plugin_mode == "overlay" ? var.pod_cidr : null
    outbound_load_balancer_public_ips = local.aks_outbound_public_ips
    outbound_ips                      = local.aks_outbound_public_ips

    # Kubernetes service network
    service_cidr   = local.service_cidr
    dns_service_ip = local.dns_service_ip

    # VNet sizing information
    vnet_size_class    = local.vnet_size_class
    vnet_total_ips     = local.vnet_total_ips
    vnet_prefix_length = local.vnet_prefix_length

    # Subnet information
    subnet_ids   = local.resolved_subnet_ids
    subnet_names = local.subnet_names

    # Organized subnet mappings
    node_pool_subnets = {
      for idx, name in local.node_pool_subnet_names : name => {
        id   = local.resolved_node_pool_subnet_ids[name]
        cidr = local.node_pool_subnet_cidrs[idx]
      }
    }

    infrastructure_subnets = {
      for idx, name in local.infrastructure_subnet_names : name => {
        id   = idx == 0 ? local.resolved_appgw_subnet_id : local.resolved_privatelink_subnet_id
        cidr = local.infrastructure_subnet_cidrs[idx]
      }
    }

    private_endpoint_subnet = {
      id   = local.resolved_privatelink_subnet_id
      name = "privatelink-subnet"
      cidr = local.infrastructure_subnet_cidrs[index(local.infrastructure_subnet_names, "privatelink-subnet")]
    }

    postgres_subnet = {
      id   = azurerm_subnet.postgres.id
      name = azurerm_subnet.postgres.name
      cidr = local.postgres_subnet_cidr
    }

    postgres_private_dns_zone = {
      id   = azurerm_private_dns_zone.postgres.id
      name = azurerm_private_dns_zone.postgres.name
    }

    redis_private_dns_zone = {
      id   = azurerm_private_dns_zone.redis.id
      name = azurerm_private_dns_zone.redis.name
    }

  }
}

output "outbound_ips" {
  description = "Public IPs used for outbound internet traffic from workloads in this environment. With egress_firewall enabled these are the firewall SNAT IPs."
  value       = local.aks_outbound_public_ips
}

output "cilium_hubble_relay_enabled" {
  description = "Whether Cilium's Hubble Relay is on in this cluster. The platform blueprint installs Hubble UI once this is true."
  value       = var.ebpf_data_plane == "cilium"
}

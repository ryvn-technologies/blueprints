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
    "client_certificate"     = module.aks.client_certificate
    "client_key"             = module.aks.client_key
    "cluster_ca_certificate" = module.aks.cluster_ca_certificate
    "cluster_fqdn"           = module.aks.cluster_fqdn
    "oidc_issuer_url"        = module.aks.oidc_issuer_url
    "location"               = module.aks.location

    "kube_config_raw"       = module.aks.kube_config_raw
    "kube_admin_config_raw" = module.aks.kube_admin_config_raw
  }
  description = "A map of AKS cluster attributes: id, name, client_certificate, client_key, cluster_ca_certificate, cluster_fqdn, oidc_issuer_url, location, kube_config_raw, kube_admin_config_raw."
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

data "azapi_resource" "aks_outbound_public_ip" {
  # No managed outbound IPs exist when outbound type is userDefinedRouting; egress
  # source IP is whatever the network virtual appliance NATs to.
  count = local.use_udr_egress ? 0 : local.aks_managed_outbound_ip_count

  type                   = "Microsoft.Network/publicIPAddresses@2023-09-01"
  resource_id            = tolist(module.aks.network_profile[0].load_balancer_profile[0].effective_outbound_ips)[count.index]
  response_export_values = ["properties.ipAddress"]

  depends_on = [module.aks]
}

locals {
  aks_outbound_public_ips = compact([
    for public_ip in data.azapi_resource.aks_outbound_public_ip :
    try(public_ip.output.properties.ipAddress, "")
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
  description = "Public IPs used for outbound internet traffic from workloads in this environment."
  value       = local.aks_outbound_public_ips
}

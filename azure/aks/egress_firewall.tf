# ============================================================================
# Default-deny cloud egress firewall (managed mode)
# ============================================================================
# Default-deny egress enforcement and explicit destination exceptions.
#
# Root responsibilities: input validation helpers, AzureFirewallSubnet at fixed
# allocator slot 4, external subnet-group allocations, route-table associations for
# every node-pool/external subnet, the post-cluster API-server exception and
# the public `egress_firewall` output. The child module owns the firewall,
# policy compilation, route table and diagnostics.

locals {
  egress_firewall_enabled = var.egress_firewall.enabled

  # Package the same ASCII-normalized PSL as AWS so each independently published
  # cloud module validates without fetching data at plan/apply time. Keep the
  # stricter hosted-service exclusions in addition to the full public suffix list.
  egress_public_suffixes = setunion(toset([
    for line in split("\n", file("${path.module}/modules/egress-firewall/public_suffix_list.dat")) :
    trimspace(line) if trimspace(line) != "" && !startswith(line, "//")
    ]), toset([
    "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk",
    "com.au", "net.au", "org.au", "edu.au", "gov.au",
    "co.nz", "net.nz", "org.nz",
    "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
    "co.in", "net.in", "org.in",
    "com.br", "net.br", "org.br",
    "co.za", "org.za",
    "com.cn", "net.cn", "org.cn",
    "com.mx", "com.ar", "com.sg", "com.hk", "com.tw", "com.tr",
    "azurewebsites.net", "cloudapp.azure.com", "cloudapp.net", "azure-api.net",
    "azurecontainer.io", "azureedge.net", "azurefd.net", "azurestaticapps.net",
    "blob.core.windows.net", "file.core.windows.net", "queue.core.windows.net", "table.core.windows.net",
    "web.core.windows.net", "dfs.core.windows.net", "azurecr.io", "trafficmanager.net",
    "amazonaws.com", "compute.amazonaws.com", "elb.amazonaws.com", "s3.amazonaws.com",
    "cloudfront.net", "elasticbeanstalk.com", "awsglobalaccelerator.com",
    "appspot.com", "cloudfunctions.net", "run.app", "web.app", "firebaseapp.com",
    "storage.googleapis.com", "googleapis.com", "withgoogle.com",
    "github.io", "githubusercontent.com", "gitlab.io", "herokuapp.com", "netlify.app",
    "vercel.app", "pages.dev", "workers.dev", "fly.dev", "onrender.com", "ngrok.io", "ngrok.app",
    "cloudflare.net", "fastly.net", "akamaized.net", "edgekey.net", "edgesuite.net",
    "dyndns.org", "no-ip.com", "duckdns.org", "nip.io", "sslip.io",
  ]))

  # Destinations that can never be an external network pinhole: default route,
  # multicast, reserved, loopback, link-local (incl. Azure 168.63.129.16 special
  # VIP and IMDS), RFC1918, and this environment's VNet/pod/service ranges.
  egress_rejected_destination_cidrs = [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "168.63.129.16/32",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4",
    var.vnet_cidr,
    var.pod_cidr,
    local.k8s_services_cidr,
  ]

  # AzureFirewallSubnet: fixed allocator slot 4 in the infrastructure half.
  # Slots 0-1 are appgw/privatelink, 2 is the service pool, 3 is postgres.
  # Existing indices never shift. /21 VNet -> /26; /16 VNet -> /24.
  egress_firewall_subnet_slot = 4
  egress_firewall_subnet_cidr = local.egress_firewall_enabled ? cidrsubnet(local.infrastructure_cidr, local.infrastructure_subnet_newbits, local.egress_firewall_subnet_slot) : null

  # Fourth quarter of the node half. Overlay owns quarters 0-2; flat owns
  # only the first three sixteenths. Infrastructure occupies the other half.
  additional_subnet_region = cidrsubnet(var.vnet_cidr, 3, 3)
  additional_subnet_prefix = tonumber(split("/", local.additional_subnet_region)[1])
  additional_subnet_prefixes_valid = alltrue([for group in var.additional_subnet_groups :
    group.ipv4_prefix_length == floor(group.ipv4_prefix_length) &&
    group.ipv4_prefix_length >= local.additional_subnet_prefix && group.ipv4_prefix_length <= 28
  ])
  additional_subnet_fits = local.additional_subnet_prefixes_valid && can(cidrsubnets(local.additional_subnet_region, [
    for group in var.additional_subnet_groups : group.ipv4_prefix_length - local.additional_subnet_prefix
  ]...))
  additional_subnet_cidrs = local.additional_subnet_fits && length(var.additional_subnet_groups) > 0 ? cidrsubnets(local.additional_subnet_region, [
    for group in var.additional_subnet_groups : group.ipv4_prefix_length - local.additional_subnet_prefix
  ]...) : []
  additional_subnet_geometry = { for position, group in var.additional_subnet_groups : group.name => {
    position           = position
    ipv4_prefix_length = group.ipv4_prefix_length
    ipv4_cidr          = try(local.additional_subnet_cidrs[position], null)
  } }
  active_subnet_groups   = { for group in var.additional_subnet_groups : group.name => group if !group.retired }
  attached_subnet_groups = [for attachment in values(var.egress_attachments) : attachment.subnet_group_key]

  # Cluster class sources: node-pool subnets. In Overlay mode pods SNAT to the
  # node address; in flat mode pods hold VNet IPs from the same subnets.
  egress_cluster_sources = local.node_pool_subnet_cidrs

  egress_classes = local.egress_firewall_enabled ? merge(
    {
      cluster = {
        kind       = "cluster"
        policy_key = var.egress_firewall.cluster_policy_key
        sources    = local.egress_cluster_sources
      }
    },
    {
      for key, attachment in var.egress_attachments : key => {
        kind       = "external"
        policy_key = attachment.policy_key
        sources    = [local.additional_subnet_geometry[attachment.subnet_group_key].ipv4_cidr]
      }
    }
  ) : {}

  egress_route_table_id = local.egress_firewall_enabled ? module.egress_firewall[0].route_table_id : null
}

# ----------------------------------------------------------------------------
# Subnets
# ----------------------------------------------------------------------------

resource "azurerm_subnet" "firewall" {
  count = local.egress_firewall_enabled ? 1 : 0

  name                 = "AzureFirewallSubnet"
  virtual_network_name = azurerm_virtual_network.main[0].name
  resource_group_name  = azurerm_resource_group.rg.name
  address_prefixes     = [local.egress_firewall_subnet_cidr]

  lifecycle {
    precondition {
      condition     = tonumber(split("/", local.egress_firewall_subnet_cidr)[1]) <= 26
      error_message = "AzureFirewallSubnet (${local.egress_firewall_subnet_cidr}) must be /26 or larger; enlarge vnet_cidr."
    }
  }
}

resource "terraform_data" "additional_subnet_contract" {
  count = length(var.additional_subnet_groups) > 0 ? 1 : 0
  input = length(var.additional_subnet_groups)

  lifecycle {
    precondition {
      condition     = local.additional_subnet_prefixes_valid
      error_message = "additional_subnet_groups ipv4_prefix_length must be an integer from /${local.additional_subnet_prefix} to /28 for the fixed allocation region ${local.additional_subnet_region}."
    }
    precondition {
      condition     = local.additional_subnet_fits
      error_message = "additional_subnet_groups do not fit in ${local.additional_subnet_region}; sequential aligned requests include retired entries. Append smaller groups or choose a larger VNet before provisioning."
    }
  }
}

resource "terraform_data" "additional_subnet_geometry" {
  for_each = local.additional_subnet_geometry
  input    = each.value

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [input]
    postcondition {
      condition     = jsonencode(self.output) == jsonencode(local.additional_subnet_geometry[each.key])
      error_message = "additional_subnet_groups[${each.key}] recorded geometry differs from the requested allocation. Keep applied entries in their original order and size (including retired tombstones); append a new group to migrate."
    }
  }

  depends_on = [terraform_data.additional_subnet_contract]
}

resource "terraform_data" "additional_subnet_ledger" {
  for_each = { for group in var.additional_subnet_groups : group.name => group }
  input = {
    position           = terraform_data.additional_subnet_geometry[each.key].output.position
    ipv4_prefix_length = terraform_data.additional_subnet_geometry[each.key].output.ipv4_prefix_length
    ipv4_cidr          = terraform_data.additional_subnet_geometry[each.key].output.ipv4_cidr
    retired            = each.value.retired
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_subnet" "additional_group" {
  for_each = local.active_subnet_groups

  name                 = "external-${replace(each.key, "_", "-")}"
  virtual_network_name = local.resolved_vnet_name
  resource_group_name  = local.resolved_vnet_rg
  address_prefixes     = [terraform_data.additional_subnet_geometry[each.key].output.ipv4_cidr]
  service_endpoints    = []

  private_endpoint_network_policies = "Enabled"
  default_outbound_access_enabled   = false
}

resource "azurerm_route_table" "additional_group" {
  for_each                      = local.active_subnet_groups
  name                          = "rt-${var.environment_name}-external-${replace(each.key, "_", "-")}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.rg.name
  bgp_route_propagation_enabled = false
  tags                          = local.tags
}

resource "azurerm_route" "additional_group_default" {
  for_each               = local.active_subnet_groups
  name                   = "default"
  resource_group_name    = azurerm_resource_group.rg.name
  route_table_name       = azurerm_route_table.additional_group[each.key].name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = contains(local.attached_subnet_groups, each.key) ? "VirtualAppliance" : "None"
  next_hop_in_ip_address = contains(local.attached_subnet_groups, each.key) ? module.egress_firewall[0].firewall_private_ip : null
}

resource "azurerm_subnet_route_table_association" "additional_group" {
  for_each       = local.active_subnet_groups
  subnet_id      = azurerm_subnet.additional_group[each.key].id
  route_table_id = azurerm_route_table.additional_group[each.key].id
  depends_on = [
    azurerm_route.additional_group_default,
    module.egress_firewall,
  ]
}

# ----------------------------------------------------------------------------
# Firewall, policy, route table, diagnostics
# ----------------------------------------------------------------------------

module "egress_firewall" {
  count  = local.egress_firewall_enabled ? 1 : 0
  source = "./modules/egress-firewall"

  depends_on = [
    azurerm_subnet.additional_group,
    azurerm_subnet.main,
    azurerm_subnet.postgres,
  ]

  name_prefix         = var.environment_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  zones               = length(local.azs) > 0 ? local.azs : null
  tags                = local.tags

  firewall_subnet_id = azurerm_subnet.firewall[0].id
  tier               = var.egress_firewall.tier
  log_retention_days = var.egress_firewall.log_retention_days

  policies               = var.egress_firewall.policies
  classes                = local.egress_classes
  platform_https_domains = local.egress_firewall_enabled ? var.platform_https_domains : []

  aks_region                         = var.location
  azure_policy_enabled               = true
  key_vault_secrets_provider_enabled = var.key_vault_secrets_provider_enabled
}

# ----------------------------------------------------------------------------
# Route-table associations: every node-pool subnet and every external class.
# ----------------------------------------------------------------------------

resource "azurerm_subnet_route_table_association" "egress_node_pool" {
  for_each = local.egress_firewall_enabled ? toset(local.node_pool_subnet_names) : toset([])

  subnet_id      = azurerm_subnet.main[each.value].id
  route_table_id = module.egress_firewall[0].route_table_id
  depends_on     = [module.egress_firewall]
}

# ----------------------------------------------------------------------------
# Post-creation control-plane exception.
# ----------------------------------------------------------------------------
# Pods outside kube-system reach the API server through the kubernetes
# ClusterIP, which DNATs to the public API IP with a non-matching SNI. The
# public FQDN only exists after the control plane is created, and the control
# plane depends on the firewall, so this rule can never be a prerequisite of
# the firewall itself. It is written to the module's stable base (parent)
# policy, which every tier-specific child policy inherits: a replacement child
# carries this rule from the moment it exists, so a tier change never attaches
# a policy that lacks it. It is a documented hostname-check bypass for the
# cluster class only (TCP/443 to the exact API-server FQDN, resolved by the
# firewall's DNS proxy).

resource "azurerm_firewall_policy_rule_collection_group" "api_server" {
  count = local.egress_firewall_enabled ? 1 : 0

  name               = "ryvn-egress-api-server"
  firewall_policy_id = module.egress_firewall[0].base_firewall_policy_id
  priority           = 200

  network_rule_collection {
    name     = "cluster-platform-api-server"
    priority = 300
    action   = "Allow"

    rule {
      name              = "cluster-platform-api-server-tcp443"
      protocols         = ["TCP"]
      source_addresses  = local.egress_cluster_sources
      destination_fqdns = [module.aks.cluster_fqdn]
      destination_ports = ["443"]
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [module.aks, module.egress_firewall]
}

# ----------------------------------------------------------------------------
# Public output
# ----------------------------------------------------------------------------

output "egress_firewall" {
  description = "Default-deny egress firewall state: configured intent, native references, versioned external attachment descriptors, compiled effective rules, log references and named exclusions. Disabled mode returns enabled=false and an empty attachment map."
  value = local.egress_firewall_enabled ? {
    enabled        = true
    default_action = var.egress_firewall.default_action
    implementation = "azure-firewall"
    policy_ref     = module.egress_firewall[0].firewall_policy_id
    enforcement_refs = {
      base_firewall_policy_id = module.egress_firewall[0].base_firewall_policy_id
      firewall_id             = module.egress_firewall[0].firewall_id
      firewall_private_ip     = module.egress_firewall[0].firewall_private_ip
      route_table_id          = module.egress_firewall[0].route_table_id
      firewall_subnet_id      = azurerm_subnet.firewall[0].id
      firewall_subnet_cidr    = local.egress_firewall_subnet_cidr
      node_pool_subnet_associations = {
        for name, association in azurerm_subnet_route_table_association.egress_node_pool : name => association.id
      }
      external_subnet_associations = {
        for key, attachment in var.egress_attachments : key => azurerm_subnet_route_table_association.additional_group[attachment.subnet_group_key].id
      }
      api_server_rule_collection_group_id = azurerm_firewall_policy_rule_collection_group.api_server[0].id
    }
    configured_scope = {
      cluster_sources     = local.egress_cluster_sources
      cluster_subnets     = { for idx, name in local.node_pool_subnet_names : name => local.node_pool_subnet_cidrs[idx] }
      external_sources    = { for key, attachment in var.egress_attachments : key => local.additional_subnet_geometry[attachment.subnet_group_key].ipv4_cidr }
      network_plugin_mode = var.network_plugin_mode
      web_ports           = { http = 80, https = 443 }
      outbound_type       = "userDefinedRouting"
    }
    attachments = {
      for key, attachment in var.egress_attachments : key => {
        schema_version      = 1
        provider            = "azure"
        subnet_group_key    = attachment.subnet_group_key
        policy_key          = attachment.policy_key
        resource_group_name = azurerm_resource_group.rg.name
        location            = var.location
        virtual_network_id  = local.resolved_vnet_id
        subnet_id           = azurerm_subnet.additional_group[attachment.subnet_group_key].id
        ipv4_cidr           = local.additional_subnet_geometry[attachment.subnet_group_key].ipv4_cidr
        route_table_id      = azurerm_route_table.additional_group[attachment.subnet_group_key].id
      }
    }
    effective_rules = concat(module.egress_firewall[0].effective_rules, [
      {
        id                      = "cluster-platform-api-server-tcp443"
        class                   = "cluster"
        source                  = "platform-cluster"
        kind                    = "network"
        action                  = "Allow"
        sources                 = local.egress_cluster_sources
        destinations            = ["<aks-api-server-fqdn>"]
        protocol                = "tcp"
        ports                   = [443]
        reason                  = "Post-creation exception: in-cluster API access via kubernetes ClusterIP DNATs to the public API IP with a non-matching SNI."
        bypasses_hostname_check = true
      }
    ])
    compiled_policy           = module.egress_firewall[0].compiled_policy
    platform_baseline_version = module.egress_firewall[0].platform_baseline_version
    log_refs                  = module.egress_firewall[0].log_refs
    exclusions = concat(module.egress_firewall[0].exclusions, [
      {
        id     = "aks-ingress-return-path"
        reason = "Public LoadBalancer services on a UDR cluster have asymmetric return paths through the firewall; ingress must use internal LB or firewall DNAT. Not covered by this module."
      },
      {
        id     = "node-pool-service-endpoints-removed"
        reason = "Storage/ACR/SQL/KeyVault service endpoints are removed from node-pool subnets in managed mode because they bypass the UDR; use private endpoints in privatelink-subnet or explicit domain allows."
      },
    ])
    } : {
    enabled                   = false
    default_action            = null
    implementation            = null
    policy_ref                = null
    enforcement_refs          = null
    configured_scope          = null
    attachments               = {}
    effective_rules           = []
    compiled_policy           = null
    platform_baseline_version = null
    log_refs                  = null
    exclusions                = []
  }

  depends_on = [
    module.egress_firewall,
    azurerm_subnet_route_table_association.egress_node_pool,
    azurerm_subnet_route_table_association.additional_group,
    azurerm_route.additional_group_default,
    azurerm_firewall_policy_rule_collection_group.api_server,
  ]
}

output "additional_subnet_groups" {
  description = "Active external network inventory, independent of firewall membership. Each subnet has an explicit default drop route until assigned to an egress attachment."
  value = { for name, group in local.active_subnet_groups : name => {
    ipv4_prefix_length = group.ipv4_prefix_length
    subnet_id          = azurerm_subnet.additional_group[name].id
    ipv4_cidr          = local.additional_subnet_geometry[name].ipv4_cidr
    route_table_id     = azurerm_route_table.additional_group[name].id
  } }
  depends_on = [azurerm_subnet_route_table_association.additional_group]
}

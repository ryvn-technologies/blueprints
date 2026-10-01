# Azure Firewall producer for the default-deny egress contract.
#
# Evaluation order in Azure Firewall is fixed: network rule collections are
# evaluated before application rule collections regardless of priority. The
# compiled policy therefore contains ONLY narrow network allows (no network
# deny-all, no permit-rest), then per-class application allows, then one final
# application DENY * on Http:80/Https:443 that overrides Azure's implicit
# infrastructure FQDN allowances. Everything else is dropped by the firewall's
# native default deny.

locals {
  name = "${var.name_prefix}-egress"

  platform_baseline_version = "azure-aks-v2"

  # Reviewed AKS/Ryvn cluster baseline. Source: AKS outbound rules
  # (https://learn.microsoft.com/azure/aks/outbound-rules-control-egress),
  # region-specialized; provider-managed FQDN tags are deliberately not used.
  aks_https_baseline = [
    "*.hcp.${lower(replace(var.aks_region, " ", ""))}.azmk8s.io",
    "mcr.microsoft.com",
    "*.data.mcr.microsoft.com",
    "mcr-0001.mcr-msedge.net",
    "management.azure.com",
    "login.microsoftonline.com",
    "packages.microsoft.com",
    "acs-mirror.azureedge.net",
    "packages.aks.azure.com",
  ]
  azure_policy_https_baseline = var.azure_policy_enabled ? [
    "data.policy.core.windows.net",
    "store.policy.core.windows.net",
    "dc.services.visualstudio.com",
  ] : []
  key_vault_https_baseline = var.key_vault_secrets_provider_enabled ? ["*.vault.azure.net"] : []

  # Ubuntu node OS security updates (HTTP repositories, apt verifies signatures).
  ubuntu_http_baseline = [
    "security.ubuntu.com",
    "azure.archive.ubuntu.com",
    "changelogs.ubuntu.com",
  ]

  docker_https_baseline = [
    "registry-1.docker.io",
    "auth.docker.io",
    "index.docker.io",
    "docker.io",
    "production.cloudflare.docker.com",
    "production.cloudfront.docker.com",
    "docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com",
  ]
  ryvn_artifact_https_baseline = [
    "charts.ryvn.app",
    "registry.ryvn.app",
  ]
  ghcr_https_baseline = [
    "ghcr.io",
    "pkg-containers.githubusercontent.com",
  ]
  kubernetes_registry_https_baseline = [
    "registry.k8s.io",
    "cdn.registry.k8s.io",
  ]
  istio_registry_https_baseline = [
    "registry.istio.io",
    "gcr.io",
    "*.pkg.dev",
  ]
  quay_https_baseline = [
    "quay.io",
    "*.quay.io",
  ]

  cluster_platform_https = {
    "aks"                 = local.aks_https_baseline
    "azure-policy"        = local.azure_policy_https_baseline
    "key-vault"           = local.key_vault_https_baseline
    "platform"            = sort(tolist(var.platform_https_domains))
    "docker"              = local.docker_https_baseline
    "ryvn-artifacts"      = local.ryvn_artifact_https_baseline
    "ghcr"                = local.ghcr_https_baseline
    "kubernetes-registry" = local.kubernetes_registry_https_baseline
    "istio-registry"      = local.istio_registry_https_baseline
    "quay"                = local.quay_https_baseline
    "acme"                = ["acme-v02.api.letsencrypt.org"]
  }
  cluster_platform_http = {
    ubuntu = local.ubuntu_http_baseline
  }

  class_keys = sort(keys(var.classes))

  # --------------------------------------------------------------------------
  # Network rule collections (narrow allows only)
  # --------------------------------------------------------------------------
  network_rule_collections = [
    for idx, class_key in local.class_keys : {
      name     = "${class_key}-customer-network"
      priority = 200 + idx
      action   = "Allow"
      rules = [
        for rule_key in sort(keys(var.policies[var.classes[class_key].policy_key].network_allow)) : {
          name                  = "${class_key}-customer-${rule_key}"
          protocols             = [upper(var.policies[var.classes[class_key].policy_key].network_allow[rule_key].protocol)]
          source_addresses      = var.classes[class_key].sources
          destination_addresses = sort(tolist(var.policies[var.classes[class_key].policy_key].network_allow[rule_key].destination_ipv4_cidrs))
          destination_fqdns     = []
          destination_ports     = [for port in sort([for p in var.policies[var.classes[class_key].policy_key].network_allow[rule_key].destination_ports : format("%05d", p)]) : tostring(tonumber(port))]
          reason                = var.policies[var.classes[class_key].policy_key].network_allow[rule_key].reason
          source                = "customer"
        }
      ]
    } if length(var.policies[var.classes[class_key].policy_key].network_allow) > 0
  ]

  # --------------------------------------------------------------------------
  # Application rule collections: per-class platform allows, per-class customer
  # allows, then the single final web deny.
  # --------------------------------------------------------------------------
  platform_application_rules = {
    for class_key in local.class_keys : class_key => concat(
      [
        for group, fqdns in local.cluster_platform_https : {
          name                  = "${class_key}-platform-${group}-https"
          source_addresses      = var.classes[class_key].sources
          destination_fqdns     = fqdns
          destination_fqdn_tags = []
          protocols             = [{ type = "Https", port = 443 }]
          terminate_tls         = false
          reason                = "AKS/Ryvn platform baseline (${group})"
          source                = "platform-cluster"
        } if length(fqdns) > 0 && var.classes[class_key].kind == "cluster"
      ],
      [
        for group, fqdns in local.cluster_platform_http : {
          name                  = "${class_key}-platform-${group}-http"
          source_addresses      = var.classes[class_key].sources
          destination_fqdns     = fqdns
          destination_fqdn_tags = []
          protocols             = [{ type = "Http", port = 80 }]
          terminate_tls         = false
          reason                = "AKS/Ryvn platform baseline (${group})"
          source                = "platform-cluster"
        } if length(fqdns) > 0 && var.classes[class_key].kind == "cluster"
      ],
    )
  }

  customer_application_rules = {
    for class_key in local.class_keys : class_key => concat(
      [for rule_key in sort(keys(var.policies[var.classes[class_key].policy_key].domain_allow)) : {
        name                  = "${class_key}-customer-${rule_key}"
        source_addresses      = var.classes[class_key].sources
        destination_fqdns     = sort(tolist(var.policies[var.classes[class_key].policy_key].domain_allow[rule_key].domains))
        destination_fqdn_tags = []
        protocols             = [{ type = title(var.policies[var.classes[class_key].policy_key].domain_allow[rule_key].protocol), port = var.policies[var.classes[class_key].policy_key].domain_allow[rule_key].destination_ports == null ? (var.policies[var.classes[class_key].policy_key].domain_allow[rule_key].protocol == "http" ? 80 : 443) : one(var.policies[var.classes[class_key].policy_key].domain_allow[rule_key].destination_ports) }]
        terminate_tls         = false
        reason                = "Customer policy ${var.classes[class_key].policy_key} ${rule_key} (HTTP Host or visible TLS SNI)"
        source                = "customer"
      }],
    )
  }

  web_deny_collection = {
    name     = "web-deny-all"
    priority = 60000
    action   = "Deny"
    rules = [{
      name                  = "deny-all-http-https"
      source_addresses      = ["*"]
      destination_fqdns     = ["*"]
      destination_fqdn_tags = []
      protocols             = [{ type = "Http", port = 80 }, { type = "Https", port = 443 }]
      terminate_tls         = false
      reason                = "Final explicit web deny; overrides implicit infrastructure FQDN allowances"
      source                = "platform"
    }]
  }

  application_rule_collections = concat(
    [
      for idx, class_key in local.class_keys : {
        name     = "${class_key}-platform-web"
        priority = 1000 + idx
        action   = "Allow"
        rules    = local.platform_application_rules[class_key]
      } if length(local.platform_application_rules[class_key]) > 0
    ],
    [
      for idx, class_key in local.class_keys : {
        name     = "${class_key}-customer-web"
        priority = 2000 + idx
        action   = "Allow"
        rules    = local.customer_application_rules[class_key]
      } if length(local.customer_application_rules[class_key]) > 0
    ],
    [local.web_deny_collection],
  )

  # --------------------------------------------------------------------------
  # Effective rules (review/output shape)
  # --------------------------------------------------------------------------
  effective_rules = concat(
    flatten([
      for collection in local.network_rule_collections : [
        for rule in collection.rules : {
          id                      = rule.name
          class                   = split("-", rule.name)[0]
          source                  = rule.source
          kind                    = "network"
          action                  = collection.action
          sources                 = rule.source_addresses
          destinations            = concat(rule.destination_addresses, rule.destination_fqdns)
          protocol                = lower(rule.protocols[0])
          ports                   = [for port in rule.destination_ports : tonumber(port)]
          reason                  = rule.reason
          bypasses_hostname_check = true
        }
      ]
    ]),
    flatten([
      for collection in local.application_rule_collections : [
        for rule in collection.rules : {
          id                      = rule.name
          class                   = collection.action == "Deny" ? "*" : split("-", rule.name)[0]
          source                  = rule.source
          kind                    = "application"
          action                  = collection.action
          sources                 = rule.source_addresses
          destinations            = rule.destination_fqdns
          protocol                = "tcp"
          ports                   = [for protocol in rule.protocols : protocol.port]
          reason                  = rule.reason
          bypasses_hostname_check = false
        }
      ]
    ]),
  )

  exclusions = [
    {
      id     = "azure-platform-vip-168-63-129-16"
      reason = "Azure wire server / DNS / health probe VIP is a platform path that does not traverse the firewall."
    },
    {
      id     = "instance-metadata-169-254-169-254"
      reason = "IMDS is link-local and never routed through the firewall."
    },
    {
      id     = "vnet-internal-and-private-endpoints"
      reason = "Intra-VNet traffic and private endpoints use system routes more specific than 0.0.0.0/0; governed by NSGs/Cilium, not this firewall."
    },
    {
      id     = "aks-control-plane-managed-egress"
      reason = "Managed control plane, node resource group extensions and Azure PaaS services' own egress are outside the customer VNet."
    },
    {
      id     = "appgw-privatelink-postgres-subnets"
      reason = "Application Gateway (unsupported 0.0.0.0/0 UDR), privatelink (inbound-only) and delegated postgres subnets are not routed through the firewall."
    },
  ]
}

resource "azurerm_public_ip" "firewall" {
  name                = "pip-${local.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones
  tags                = var.tags
}

# Firewall Policy SKU is immutable (ForceNew in azurerm), while the firewall's own
# sku_tier and policy attachment update in place. A tier change therefore builds the
# complete replacement child policy and its own rules first (rules living on the base
# policy are inherited immediately), then re-points the firewall in the same PUT that
# changes its tier, and only then destroys the previous child policy.
# The replacement needs a name that cannot collide with any policy still present:
# the retired one is kept until the switch succeeds, and after a failed tier change
# the firewall is still attached to it, so rolling back to the same tier with a static
# per-tier name would fail with "already exists". A new generation is drawn whenever
# the tier changes.
resource "random_id" "policy_generation" {
  byte_length = 2

  keepers = {
    tier = var.tier
  }
}

locals {
  firewall_policy_name_prefix = "afwp-${local.name}-${lower(var.tier)}-"
}

# Base (parent) policy. It carries the rules that can only be written after the
# cluster exists (the root's API-server exception) and is never replaced: Azure
# inherits a parent's rule collections into every child and lets a Standard
# parent sit under a Standard or Premium child (the reverse is rejected with
# FirewallPolicyBasePolicyCannotBeHigherSku), so the tier lives only on the
# child. A replacement child therefore inherits the API-server rule the moment
# it is created, before the firewall is re-pointed at it. DNS proxy must be on
# here as well: Azure validates network FQDN rules against the policy that owns
# them.
resource "azurerm_firewall_policy" "base" {
  name                     = "afwp-${local.name}-base"
  location                 = var.location
  resource_group_name      = var.resource_group_name
  sku                      = "Standard"
  threat_intelligence_mode = "Alert"
  tags                     = var.tags

  dns {
    proxy_enabled = true
  }
}

resource "azurerm_firewall_policy" "egress" {
  name                     = "${local.firewall_policy_name_prefix}${random_id.policy_generation.hex}"
  location                 = var.location
  resource_group_name      = var.resource_group_name
  sku                      = var.tier
  base_policy_id           = azurerm_firewall_policy.base.id
  threat_intelligence_mode = "Alert"
  tags                     = var.tags

  dns {
    proxy_enabled = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  name               = "ryvn-egress"
  firewall_policy_id = azurerm_firewall_policy.egress.id
  priority           = 100

  lifecycle {
    create_before_destroy = true
  }

  dynamic "network_rule_collection" {
    for_each = local.network_rule_collections
    content {
      name     = network_rule_collection.value.name
      priority = network_rule_collection.value.priority
      action   = network_rule_collection.value.action

      dynamic "rule" {
        for_each = network_rule_collection.value.rules
        content {
          name                  = rule.value.name
          protocols             = rule.value.protocols
          source_addresses      = rule.value.source_addresses
          destination_addresses = length(rule.value.destination_addresses) > 0 ? rule.value.destination_addresses : null
          destination_fqdns     = length(rule.value.destination_fqdns) > 0 ? rule.value.destination_fqdns : null
          destination_ports     = rule.value.destination_ports
        }
      }
    }
  }

  dynamic "application_rule_collection" {
    for_each = local.application_rule_collections
    content {
      name     = application_rule_collection.value.name
      priority = application_rule_collection.value.priority
      action   = application_rule_collection.value.action

      dynamic "rule" {
        for_each = application_rule_collection.value.rules
        content {
          name              = rule.value.name
          source_addresses  = rule.value.source_addresses
          destination_fqdns = rule.value.destination_fqdns
          terminate_tls     = false

          dynamic "protocols" {
            for_each = rule.value.protocols
            content {
              type = protocols.value.type
              port = protocols.value.port
            }
          }
        }
      }
    }
  }
}

resource "azurerm_firewall" "egress" {
  name                = "afw-${local.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "AZFW_VNet"
  sku_tier            = var.tier
  firewall_policy_id  = azurerm_firewall_policy.egress.id
  zones               = var.zones
  tags                = var.tags

  ip_configuration {
    name                 = "primary"
    subnet_id            = var.firewall_subnet_id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  depends_on = [azurerm_firewall_policy_rule_collection_group.egress]
}

# Manage the inspected default as a separate resource, so this table does not
# claim an inline route set. Azure CNI Overlay does not require pod CIDR routes.
resource "azurerm_route_table" "egress" {
  name                          = "rt-${local.name}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  bgp_route_propagation_enabled = false
  tags                          = var.tags
}

resource "azurerm_route" "internet" {
  name                   = "default-via-firewall"
  resource_group_name    = var.resource_group_name
  route_table_name       = azurerm_route_table.egress.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.egress.ip_configuration[0].private_ip_address
}

resource "azurerm_log_analytics_workspace" "egress" {
  name                = "law-${local.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

locals {
  diagnostic_log_categories = ["AZFWApplicationRule", "AZFWNetworkRule", "AZFWDnsQuery"]
}

resource "azurerm_monitor_diagnostic_setting" "firewall" {
  name                           = "egress-verdicts"
  target_resource_id             = azurerm_firewall.egress.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.egress.id
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = local.diagnostic_log_categories
    content {
      category = enabled_log.value
    }
  }
}

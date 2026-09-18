# Public module: github.com/ryvn-technologies/blueprints//azure/azure-container-registry

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.6.0"

  backend "kubernetes" {}
}

provider "azurerm" {
  features {}
}

resource "random_id" "suffix" {
  byte_length = 4
}

data "azurerm_kubernetes_cluster" "this" {
  count = local.lookup_cluster ? 1 : 0

  name                = var.cluster_name
  resource_group_name = coalesce(var.cluster_resource_group_name, var.resource_group_name)
}

locals {
  # ACR names are globally unique, 5-50 alphanumeric characters. The 8-char
  # hex suffix leaves plenty of room for the sanitised base name.
  base_name     = coalesce(var.registry_name, var.name_prefix)
  registry_name = "${substr(replace(lower(local.base_name), "/[^a-z0-9]/", ""), 0, 42)}${random_id.suffix.hex}"

  all_tags = merge(var.tags, {
    terraform   = "true"
    environment = var.environment
    managed-by  = "ryvn"
  })

  # The AKS cluster supplies the kubelet identity (merged with the explicit
  # list) and, unless pinned, the OIDC issuer for the copier's federated
  # credential. Attached clusters must pass both explicitly.
  detect_node_identities = var.cluster_name != ""
  detect_oidc_issuer     = var.cluster_name != "" && var.oidc_issuer_url == ""
  lookup_cluster         = local.detect_node_identities || local.detect_oidc_issuer

  detected_node_principal_ids = local.detect_node_identities ? [
    for identity in data.azurerm_kubernetes_cluster.this[0].kubelet_identity : identity.object_id
  ] : []

  node_principal_ids = distinct(concat(var.node_principal_ids, local.detected_node_principal_ids))
  pull_principal_ids = distinct(concat(local.node_principal_ids, var.pull_principal_ids))
  oidc_issuer_url    = var.oidc_issuer_url != "" ? var.oidc_issuer_url : (local.detect_oidc_issuer ? data.azurerm_kubernetes_cluster.this[0].oidc_issuer_url : "")

  push_role = "AcrPush"
  pull_role = "AcrPull"
}

resource "azurerm_container_registry" "this" {
  name                          = local.registry_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = var.sku
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = var.public_network_access_enabled
  zone_redundancy_enabled       = var.zone_redundancy_enabled
  tags                          = local.all_tags

  lifecycle {
    precondition {
      condition     = !var.require_node_pull_grant || length(local.node_principal_ids) > 0
      error_message = "No kubelet identities were resolved for node pull access. Set node_principal_ids explicitly (required for attached clusters) or set require_node_pull_grant = false."
    }
    precondition {
      condition     = local.oidc_issuer_url != ""
      error_message = "The cluster OIDC issuer URL is required to federate the copier's Kubernetes service account. Set oidc_issuer_url explicitly (required for attached clusters) or set cluster_name."
    }
  }
}

# ---------------------------------------------------------------------------
# Push identity: user-assigned identity federated to the copier's Kubernetes
# service account(s) via Workload Identity. No registry credentials exist.
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "push" {
  name                = "${local.registry_name}-push"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.all_tags
}

resource "azurerm_federated_identity_credential" "push" {
  for_each = toset(var.push_service_accounts)

  name                      = "${local.registry_name}-${each.value}"
  user_assigned_identity_id = azurerm_user_assigned_identity.push.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = local.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.push_namespace}:${each.value}"
}

resource "azurerm_role_assignment" "push" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = local.push_role
  principal_id         = azurerm_user_assigned_identity.push.principal_id
  principal_type       = "ServicePrincipal"
}

# ---------------------------------------------------------------------------
# Pull identity: kubelet identities get AcrPull on the registry
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "node_pull" {
  for_each = toset(local.pull_principal_ids)

  scope                = azurerm_container_registry.this.id
  role_definition_name = local.pull_role
  principal_id         = each.value
  principal_type       = "ServicePrincipal"
}
# Distributed to BYOC hubs as a public module (github.com/ryvn-technologies/blueprints).

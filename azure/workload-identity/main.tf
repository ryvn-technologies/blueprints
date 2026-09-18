terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  # optional() attribute defaults on the role_groups variable need 1.3+.
  required_version = ">= 1.3.0"

  backend "kubernetes" {}
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

locals {
  all_tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment
  })

  # Resolve each group's identity name: explicit role_name wins, otherwise the map key.
  # Managed identity names allow 3-128 characters of letters, digits, hyphens and underscores.
  identity_names = {
    for group_name, group in var.role_groups :
    group_name => substr(replace("${var.name_prefix}-${coalesce(group.role_name, group_name)}", "/[^A-Za-z0-9_-]/", "-"), 0, 128)
  }

  # One entry per Kubernetes subject, keyed "<group>/<association key>".
  subjects = merge([
    for group_name, group in var.role_groups : {
      for assoc_key, assoc in group.associations :
      "${group_name}/${assoc_key}" => {
        group           = group_name
        namespace       = assoc.namespace
        service_account = assoc.service_account
      }
    }
  ]...)

  # Federated credential names allow 3-120 characters of letters, digits, hyphens
  # and underscores, starting with a letter or digit.
  credential_names = {
    for key, subject in local.subjects :
    key => substr(replace("${var.name_prefix}-${key}", "/[^A-Za-z0-9_-]/", "-"), 0, 120)
  }

  # Flatten role assignments across groups, keyed "<group>/<assignment key>".
  role_assignments = merge([
    for group_name, group in var.role_groups : {
      for assignment_key, assignment in group.role_assignments :
      "${group_name}/${assignment_key}" => {
        group                = group_name
        scope                = assignment.scope
        role_definition_name = assignment.role_definition_name
      }
    }
  ]...)
}

# One user-assigned managed identity per group. This is the principal the
# group's pods run as.
resource "azurerm_user_assigned_identity" "this" {
  for_each = var.role_groups

  name                = local.identity_names[each.key]
  location            = var.location
  resource_group_name = var.resource_group_name

  tags = local.all_tags
}

# Trust: one federated credential per subject. Entra ID exchanges a projected
# ServiceAccount token whose issuer and subject match for a token of the
# identity. Subjects are exact matches; wildcards are not supported.
resource "azurerm_federated_identity_credential" "this" {
  for_each = local.subjects

  name                = local.credential_names[each.key]
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.this[each.value.group].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.oidc_issuer_url
  subject             = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}

# Role assignments for the group's identity.
resource "azurerm_role_assignment" "this" {
  for_each = local.role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role_definition_name
  principal_id         = azurerm_user_assigned_identity.this[each.value.group].principal_id
  principal_type       = "ServicePrincipal"

  # The identity was created moments ago; skip the directory lookup that can
  # fail on replication lag.
  skip_service_principal_aad_check = true
}
# Distributed to BYOC hubs as a public module (github.com/ryvn-technologies/blueprints).

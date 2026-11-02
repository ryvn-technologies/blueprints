data "azurerm_subscription" "main" {}

locals {
  executor_override            = var.terraform_executor_policies.permissions != null || length(var.terraform_executor_policies.role_assignments) > 0
  executor_custom_role_enabled = !local.executor_override || var.terraform_executor_policies.permissions != null
  executor_permissions = var.terraform_executor_policies.permissions != null ? var.terraform_executor_policies.permissions : {
    actions          = ["*"]
    not_actions      = []
    data_actions     = null
    not_data_actions = null
    scope            = null
    condition        = null
  }
}

resource "azurerm_role_definition" "agent" {
  count = local.executor_custom_role_enabled ? 1 : 0

  name        = "ryvn-agent-role-${var.environment_name}"
  scope       = data.azurerm_subscription.main.id
  description = "Role used by ryvn-agent to manage infrastructure."

  permissions {
    actions          = local.executor_permissions.actions
    not_actions      = local.executor_permissions.not_actions
    data_actions     = local.executor_permissions.data_actions
    not_data_actions = local.executor_permissions.not_data_actions
  }

  assignable_scopes = [
    data.azurerm_subscription.main.id,
  ]
}

moved {
  from = azurerm_role_definition.agent
  to   = azurerm_role_definition.agent[0]
}

resource "azurerm_user_assigned_identity" "ryvn_agent" {
  name                = "ryvn-agent-${var.environment_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "role_assignment" {
  count = local.executor_custom_role_enabled ? 1 : 0

  scope                = coalesce(local.executor_permissions.scope, data.azurerm_subscription.main.id)
  role_definition_name = azurerm_role_definition.agent[0].name
  principal_id         = azurerm_user_assigned_identity.ryvn_agent.principal_id
  condition            = local.executor_permissions.condition
  condition_version    = local.executor_permissions.condition != null ? "2.0" : null
}

moved {
  from = azurerm_role_assignment.role_assignment
  to   = azurerm_role_assignment.role_assignment[0]
}

resource "azurerm_role_assignment" "executor" {
  for_each = var.terraform_executor_policies.role_assignments

  scope                            = coalesce(each.value.scope, data.azurerm_subscription.main.id)
  role_definition_name             = each.value.role_definition_name
  role_definition_id               = each.value.role_definition_id
  principal_id                     = azurerm_user_assigned_identity.ryvn_agent.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  condition                        = each.value.condition
  condition_version                = each.value.condition != null ? "2.0" : null
}

resource "azurerm_federated_identity_credential" "ryvn_agent" {
  name                = "ryvn-agent-${var.environment_name}"
  resource_group_name = azurerm_resource_group.rg.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.ryvn_agent.id
  subject             = "system:serviceaccount:${var.ryvn_system_namespace}:ryvn-agent"
}

# Create managed identity for cert-manager
resource "azurerm_user_assigned_identity" "cert_manager" {
  name                = "cert-manager-${var.environment_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.tags
}

# Federate the managed identity with the Kubernetes service account
resource "azurerm_federated_identity_credential" "cert_manager" {
  name                = "cert-manager-${var.environment_name}"
  resource_group_name = azurerm_resource_group.rg.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.cert_manager.id
  subject             = "system:serviceaccount:cert-manager:cert-manager"
}

# Grant DNS Zone Contributor role for public DNS zone
resource "azurerm_role_assignment" "cert_manager_public" {
  scope                = azurerm_dns_zone.public.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.cert_manager.principal_id
}

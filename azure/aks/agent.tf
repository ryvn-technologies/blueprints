data "azurerm_subscription" "main" {}

resource "azurerm_role_definition" "agent" {
  name        = "ryvn-agent-role-${var.environment_name}"
  scope       = data.azurerm_subscription.main.id
  description = "Role used by ryvn-agent to manage infrastructure."

  permissions {
    actions     = ["*"]
    not_actions = []
  }

  assignable_scopes = [
    data.azurerm_subscription.main.id,
  ]
}

resource "azurerm_user_assigned_identity" "ryvn_agent" {
  name                = "ryvn-agent-${var.environment_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "role_assignment" {
  scope                = data.azurerm_subscription.main.id
  role_definition_name = azurerm_role_definition.agent.name
  principal_id         = azurerm_user_assigned_identity.ryvn_agent.principal_id
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

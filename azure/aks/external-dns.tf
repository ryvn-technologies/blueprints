# Create managed identity for ExternalDNS (public zone)
resource "azurerm_user_assigned_identity" "external_dns" {
  name                = "external-dns-${var.environment_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.tags
}

# Create managed identity for ExternalDNS (private zone)
resource "azurerm_user_assigned_identity" "external_dns_private" {
  name                = "ext-dns-private-${var.environment_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.tags
}

# Federate the managed identity with the Kubernetes service account (public zone)
resource "azurerm_federated_identity_credential" "external_dns" {
  name                = "external-dns-${var.environment_name}"
  resource_group_name = azurerm_resource_group.rg.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.external_dns.id
  subject             = "system:serviceaccount:external-dns:external-dns"
}

# Federate the managed identity with the Kubernetes service account (private zone)
resource "azurerm_federated_identity_credential" "external_dns_private" {
  name                = "ext-dns-private-${var.environment_name}"
  resource_group_name = azurerm_resource_group.rg.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.external_dns_private.id
  subject             = "system:serviceaccount:external-dns:external-dns-private"
}

# Grant DNS Zone Contributor role for public DNS zone
resource "azurerm_role_assignment" "external_dns_public" {
  scope                = azurerm_dns_zone.public.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.external_dns.principal_id
}

# Grant DNS Zone Contributor role for private DNS zone
resource "azurerm_role_assignment" "external_dns_private" {
  scope                = azurerm_private_dns_zone.internal.id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.external_dns_private.principal_id
}
 
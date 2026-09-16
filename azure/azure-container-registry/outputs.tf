output "registry_host" {
  description = "ACR login server (e.g. registryabcd1234.azurecr.io)"
  value       = azurerm_container_registry.this.login_server
}

output "path_prefix" {
  description = "Path prepended to the source image path when pulling from this registry. ACR keeps the source path as-is."
  value       = ""
}

output "registry_id" {
  description = "Azure resource id of the container registry"
  value       = azurerm_container_registry.this.id
}

output "registry_name" {
  description = "Name of the container registry"
  value       = azurerm_container_registry.this.name
}

output "destination_base" {
  description = "Base image reference under which mirrored artifacts are pushed. ACR namespaces repositories by path, so this is the login server itself."
  value       = azurerm_container_registry.this.login_server
}

output "region" {
  description = "Azure region of the registry"
  value       = azurerm_container_registry.this.location
}

output "resource_group_name" {
  description = "Resource group that owns the registry"
  value       = azurerm_container_registry.this.resource_group_name
}

output "registry_definition" {
  description = "Registry definition in the shape of the Ryvn registry API (GenericContainerRegistry with clusterDefault credentials: nodes pull through their kubelet identity). Contains no secrets."
  value = {
    type    = "genericContainerRegistry"
    url     = azurerm_container_registry.this.login_server
    subType = "azureContainerRegistry"
    credentials = {
      type = "clusterDefault"
    }
  }
}

output "push_identity" {
  description = "Non-secret description of how the artifact copier authenticates to push"
  value = {
    method          = "azureWorkloadIdentity"
    namespace       = var.push_namespace
    serviceAccounts = var.push_service_accounts
    clientId        = azurerm_user_assigned_identity.push.client_id
    principalId     = azurerm_user_assigned_identity.push.principal_id
    tenantId        = azurerm_user_assigned_identity.push.tenant_id
    role            = local.push_role
    oidcIssuerUrl   = local.oidc_issuer_url
  }
}

output "pull_identity" {
  description = "Non-secret description of how cluster nodes authenticate to pull"
  value = {
    method       = "azureKubeletIdentity"
    principalIds = local.node_principal_ids
    role         = local.pull_role
    detected     = local.detect_node_identities
  }
}

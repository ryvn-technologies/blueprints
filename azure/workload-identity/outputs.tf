output "identities" {
  description = "Managed identity per group: id, client_id, principal_id, tenant_id"
  value = {
    for group_name, identity in azurerm_user_assigned_identity.this :
    group_name => {
      id           = identity.id
      client_id    = identity.client_id
      principal_id = identity.principal_id
      tenant_id    = identity.tenant_id
    }
  }
}

output "client_ids" {
  description = "Client ID per group. Set azure.workload.identity/client-id on the group's ServiceAccounts to this value."
  value       = { for group_name, identity in azurerm_user_assigned_identity.this : group_name => identity.client_id }
}

output "tenant_id" {
  description = "Tenant ID. Set azure.workload.identity/tenant-id on the ServiceAccounts to this value."
  value       = data.azurerm_client_config.current.tenant_id
}

output "principals" {
  description = "Principal identifiers per group, in the form resource-side grants accept (the identity's principal ID). Same shape on every cloud."
  value       = { for group_name, identity in azurerm_user_assigned_identity.this : group_name => [identity.principal_id] }
}

output "federated_credential_ids" {
  description = "Federated credential ID per subject, keyed <group>/<association key>"
  value       = { for key, credential in azurerm_federated_identity_credential.this : key => credential.id }
}

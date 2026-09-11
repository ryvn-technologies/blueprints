output "bucket_name" {
  description = "Name of the blob container (including the random suffix)"
  value       = azurerm_storage_container.this.name
}

output "bucket_id" {
  description = "Cloud-native identifier for the bucket (the container's Azure Resource Manager ID)"
  value       = azurerm_storage_container.this.id
}

output "bucket_domain_name" {
  description = "Blob endpoint host of the storage account (e.g. myaccount.blob.core.windows.net)"
  value       = azurerm_storage_account.this.primary_blob_host
}

output "region" {
  description = "Azure region where the storage account was created"
  value       = azurerm_storage_account.this.location
}

output "endpoint" {
  description = "Blob service endpoint URL of the storage account"
  value       = trimsuffix(azurerm_storage_account.this.primary_blob_endpoint, "/")
}

output "storage_account_name" {
  description = "Name of the storage account that holds the container"
  value       = azurerm_storage_account.this.name
}

output "storage_account_id" {
  description = "Resource ID of the storage account"
  value       = azurerm_storage_account.this.id
}

output "role_assignment_scope" {
  description = "Azure Resource Manager ID of the container, the scope for granting workloads access to this bucket. Pass it to the workload identity module's role_groups.<group>.role_assignments.<key>.scope."
  value       = azurerm_storage_container.this.id
}

output "role_definition_name" {
  description = "Built-in role granting read/write access to blobs in this container. Pass it to the workload identity module's role_groups.<group>.role_assignments.<key>.role_definition_name."
  value       = "Storage Blob Data Contributor"
}

output "workload_grants" {
  description = "Grants for the workload identity module. Each entry maps to role_groups.<group>.role_assignments.<key>."
  value = [{
    scope                = azurerm_storage_container.this.id
    role_definition_name = "Storage Blob Data Contributor"
  }]
}

output "encryption_key_id" {
  description = "Customer-managed Key Vault key used for encryption, or empty when Microsoft-managed keys are used."
  value       = var.encryption_key_id
}

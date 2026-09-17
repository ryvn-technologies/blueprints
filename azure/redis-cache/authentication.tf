# Microsoft Entra authentication is always on for Azure Managed Redis; these
# assignments grant principals the built-in default access policy (full
# access) on the default database.
resource "azurerm_managed_redis_access_policy_assignment" "this" {
  for_each = var.entra_principals

  managed_redis_id = azurerm_managed_redis.this.id
  object_id        = each.value.object_id

  lifecycle {
    precondition {
      condition     = length(distinct([for principal in var.entra_principals : lower(principal.object_id)])) == length(var.entra_principals)
      error_message = "entra_principals object IDs must be distinct."
    }
  }
}

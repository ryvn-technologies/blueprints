# Azure Blob Container Module

Provisions a dedicated StorageV2 storage account with a single blob container, optional blob versioning and lifecycle rules, optional browser CORS configuration, and an optional `CanNotDelete` lock. The module creates no role assignments: it publishes the container's resource ID as the grant scope, and the [workload identity module](../../ryvn-workload-identity/azure/README.md) assigns `Storage Blob Data Contributor` on that scope to the workloads' managed identities.

One storage account per bucket keeps account-level settings (versioning, CORS, lifecycle, replication) from leaking between buckets and lets the container map 1:1 onto the S3/GCS bucket model.

## Usage

```hcl
module "bucket" {
  source = "./infra/ryvn-bucket/azure"

  location            = "eastus"
  resource_group_name = "my-rg"
  name_prefix         = "my-app"
  environment         = "production"
}

module "workload_identity" {
  source = "./infra/ryvn-workload-identity/azure"

  # ...
  role_groups = {
    app = {
      associations = { api = { namespace = "prod", service_account = "api" } }
      role_assignments = {
        media = {
          scope                = module.bucket.role_assignment_scope
          role_definition_name = module.bucket.role_definition_name
        }
      }
    }
  }
}
```

## What's Included

- **Storage account**: `StorageV2`, Standard tier, `LRS` by default, TLS 1.2 minimum, HTTPS only. Name is `bucket_name`/`name_prefix` stripped to `[a-z0-9]`, truncated to 16 chars, plus an 8-char random suffix (24-char account limit)
- **Container**: Named from the same prefix (non-alphanumeric runs collapsed to single hyphens, no leading/trailing hyphen, `bucket` fallback) plus the random suffix. This is the blueprint's `bucketName`
- **Encryption**: Microsoft-managed keys (always on)
- **Access control**: Container `private`, `allow_nested_items_to_be_public = false` by default (`public_access = false`). Account keys are disabled (`shared_access_key_enabled = false`, `default_to_oauth_authentication = true`), so the only access path is Entra ID / RBAC on the container scope; presigned URLs must use user-delegation SAS. The provisioning principal therefore needs a data-plane role (e.g. `Storage Blob Data Owner`) on the account, and the provider runs with `storage_use_azuread = true`. The module accepts `public_access = true` for direct consumers, but the bucket blueprint does not expose it.
- **Networking**: `public_network_access = true` by default (workloads egress over public IPs); no network rules or private endpoints
- **CORS**: Optional blob-service CORS rules (Azure allows at most 5)
- **Versioning**: Off by default, opt-in via `versioning`
- **Lifecycle**: A management policy scoped to the container prefix with optional base-blob expiration (`delete_after_days_since_modification_greater_than`) and previous-version expiration (`delete_after_days_since_creation`)
- **Deletion protection**: `CanNotDelete` lock on the storage account when `deletion_protection = true`. This blocks out-of-band deletes only: a Terraform destroy removes the lock first and then deletes the account and its data, unlike `force_destroy = false` on AWS/GCP which fails on a non-empty bucket

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `location` | Azure region | required |
| `resource_group_name` | Resource group for the storage account | required |
| `name_prefix` | Fallback prefix for account/container names when `bucket_name` is empty | required |
| `bucket_name` | Desired container name (random suffix appended automatically) | `""` |
| `environment` | Environment name | required |
| `replication_type` | Storage account replication (`LRS`, `ZRS`, `GRS`, `RAGRS`, `GZRS`, `RAGZRS`) | `"LRS"` |
| `versioning` | Enable blob versioning | `false` |
| `public_access` | Allow anonymous blob reads. Not exposed by the bucket blueprint. | `false` |
| `shared_access_key_enabled` | Allow storage account keys / account-key SAS | `false` |
| `public_network_access` | Allow access over public endpoints | `true` |
| `cors_rules` | Browser CORS rules for the blob service | `[]` |
| `expiration_days` | Delete current blobs N days after last modification (0 = disabled) | `0` |
| `noncurrent_version_expiration_days` | Delete previous versions N days after creation (0 = disabled; requires versioning) | `0` |
| `deletion_protection` | Add a `CanNotDelete` lock on the account. Guards against portal/CLI deletes, not against destroying this module | `true` |
| `encryption_key_id` | Key Vault key resource ID (`.../Microsoft.KeyVault/vaults/<v>/keys/<k>`) bound versionless as the account's customer-managed key. Empty = Microsoft-managed. Requires an RBAC vault with purge protection; the account's system-assigned identity gets `Key Vault Crypto Service Encryption User` on the vault | `""` |
| `tags` | Tags for all resources | `{}` |

`cors_rules` has the same shape as the AWS module.

## Outputs

| Name | Description |
|------|-------------|
| `bucket_name` | Container name (prefix + random suffix) |
| `bucket_id` | Container Resource Manager ID |
| `bucket_domain_name` | `<account>.blob.core.windows.net` |
| `region` | Storage account location |
| `endpoint` | `https://<account>.blob.core.windows.net` |
| `storage_account_name` | Storage account name |
| `storage_account_id` | Storage account resource ID |
| `role_assignment_scope` | Container Resource Manager ID (with `storage_account_id`, azurerm 4.x's container `id` is the ARM ID); feed to the workload identity module's `role_assignments.<key>.scope` |
| `role_definition_name` | `Storage Blob Data Contributor`; feed to `role_assignments.<key>.role_definition_name` |
| `encryption_key_id` | The `encryption_key_id` in use, or empty |
| `workload_grants` | `[{ scope, role_definition_name }]` — same grant in the cross-cloud list shape every bucket module exposes |

## Prerequisites

- The identity running Terraform can create storage accounts and management locks in the resource group. Role assignments are written by the workload identity module, which needs `Microsoft.Authorization/roleAssignments/write` on the container scope (e.g. `User Access Administrator` or `Owner` on the resource group).

## One-Way Decisions

These cannot be changed after creation: storage account name, container name, account kind/tier, location.

## Future Additions

- Unified `publicAccess` mode for hosting public static content (cross-cloud; deferred)
- Customer-managed keys (Key Vault)
- Access-tier transitions (Cool, Cold, Archive) in the lifecycle policy
- Immutability policies / legal holds
- Private endpoints and `public_network_access_enabled = false`
- Event Grid notifications

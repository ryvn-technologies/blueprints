# Azure Managed Redis Module

Terraform module for provisioning Azure Managed Redis.

## Features

- Managed Redis SKUs: Balanced_B, ComputeOptimized_X, MemoryOptimized_M, FlashOptimized_A
- Optional high availability (two-node replicated deployment, 99.999% SLA)
- TLS-only access (Encrypted client protocol, port 10000)
- Optional Private Link access via `privatelink.redis.azure.net`
- Optional customer-managed key encryption with a user-assigned identity
- Optional RDB persistence
- Microsoft Entra (passwordless) authentication via access policy assignments, with optional access-key disable

## Usage

```hcl
module "cache" {
  source = "./infra/ryvn-cache/azure"

  installation_name   = "my-app-cache"
  environment         = "production"
  resource_group_name = azurerm_resource_group.this.name
  location            = "eastus"

  # SKU
  sku_name = "Balanced_B3"

  tags = {
    Project = "my-application"
  }
}
```

### Minimal

```hcl
module "cache" {
  source = "./infra/ryvn-cache/azure"

  installation_name   = "my-app-cache"
  environment         = "staging"
  resource_group_name = azurerm_resource_group.this.name

  high_availability_enabled = false
}
```

### Private Link Access

```hcl
module "cache" {
  source = "./infra/ryvn-cache/azure"

  installation_name   = "my-app-cache"
  environment         = "production"
  resource_group_name = azurerm_resource_group.this.name

  private_endpoint_subnet_id = azurerm_subnet.private_endpoints.id
  private_dns_zone_id        = azurerm_private_dns_zone.redis.id
}
```

### Customer-Managed Key

```hcl
module "cache" {
  source = "./infra/ryvn-cache/azure"

  installation_name   = "my-app-cache"
  environment         = "production"
  resource_group_name = azurerm_resource_group.this.name

  customer_managed_key_id          = azurerm_key_vault_key.redis.id
  customer_managed_key_identity_id = azurerm_user_assigned_identity.redis.id
}
```

The user-assigned identity needs get, wrapKey, and unwrapKey on the Key Vault
key (the Key Vault Crypto Service Encryption User role).

### Entra Authentication (passwordless)

```hcl
module "workload_identity" {
  source = "./infra/ryvn-workload-identity/azure"
  # ...
  role_groups = {
    api = { associations = { api = { namespace = "app", service_account = "api" } } }
  }
}

module "cache" {
  source = "./infra/ryvn-cache/azure"

  installation_name   = "my-app-cache"
  environment         = "production"
  resource_group_name = azurerm_resource_group.this.name

  entra_principals = {
    api = { object_id = module.workload_identity.identities["api"].principal_id }
  }

  # Once every client uses Entra tokens, turn off access keys entirely.
  access_keys_authentication_enabled = false
}
```

Entra authentication is always available on Azure Managed Redis; the module
creates an `azurerm_managed_redis_access_policy_assignment` per entry in
`entra_principals`, granting that principal the built-in default access policy
(full access) on the default database. Nothing has to be created by hand
after apply. Setting `access_keys_authentication_enabled = false` makes the
cache passwordless: `primary_access_key` and `auth_token` output null and
`connection_url` contains no credentials. It requires at least one principal.

Clients authenticate with the principal's **object ID** as the Redis username
and an Entra access token for scope `https://redis.azure.com/.default`
(`entra_token_scope` output) as the password. Tokens expire, so long-lived
connections must re-`AUTH` with a fresh token before expiry (see "Use
Microsoft Entra for cache authentication" in the Azure Managed Redis docs for
per-language client guidance).

Caveats:

- TLS is required (already enforced by this module).
- Only individual principals are supported: Microsoft Entra groups are not.
- The AzureRM provider only exposes the default access policy (full access);
  read-only policies are not available through Terraform today, so
  least-privilege split logins are not possible on Azure yet.
- Toggling `access_keys_authentication_enabled` disconnects all clients.

## Required Variables

- `installation_name`: Identifier for the cache instance
- `environment`: Environment name
- `resource_group_name`: Azure resource group

## Optional Variables

| Variable | Default | Description |
|---|---|---|
| `location` | `"eastus"` | Azure region |
| `sku_name` | `"Balanced_B1"` | Managed Redis SKU (see the SKU list below) |
| `high_availability_enabled` | `true` | Two-node replicated deployment (99.999% SLA). Cannot be changed after creation |
| `clustering_policy` | `"EnterpriseCluster"` | `EnterpriseCluster`, `OSSCluster`, or `NoCluster`. Changing recreates the database |
| `eviction_policy` | `"VolatileLRU"` | Eviction policy when the memory limit is reached |
| `rdb_backup_frequency` | `null` | RDB persistence frequency (`1h`, `6h`, `12h`; null disables persistence) |
| `access_keys_authentication_enabled` | `true` | Keep access-key auth on the default database; `false` = Entra-only (needs `entra_principals`) |
| `entra_principals` | `{}` | `{ alias = { object_id } }` principals granted the default access policy |
| `customer_managed_key_id` | `null` | Versioned Key Vault key ID for customer-managed encryption |
| `customer_managed_key_identity_id` | `null` | User-assigned identity for Key Vault access (required with `customer_managed_key_id`) |
| `private_endpoint_subnet_id` | `null` | Private endpoint subnet ID |
| `private_dns_zone_id` | `null` | Private DNS zone ID for `privatelink.redis.azure.net` |

## SKU Names

`Balanced_B0`, `Balanced_B1`, `Balanced_B3`, `Balanced_B5`, `Balanced_B10`, `Balanced_B20`, `Balanced_B50`, `Balanced_B100`, `Balanced_B150`, `Balanced_B250`, `Balanced_B350`, `Balanced_B500`, `Balanced_B700`, `Balanced_B1000`, `ComputeOptimized_X3`, `ComputeOptimized_X5`, `ComputeOptimized_X10`, `ComputeOptimized_X20`, `ComputeOptimized_X50`, `ComputeOptimized_X100`, `ComputeOptimized_X150`, `ComputeOptimized_X250`, `ComputeOptimized_X350`, `ComputeOptimized_X500`, `ComputeOptimized_X700`, `MemoryOptimized_M10`, `MemoryOptimized_M20`, `MemoryOptimized_M50`, `MemoryOptimized_M100`, `MemoryOptimized_M150`, `MemoryOptimized_M250`, `MemoryOptimized_M350`, `MemoryOptimized_M500`, `MemoryOptimized_M700`, `MemoryOptimized_M1000`, `MemoryOptimized_M1500`, `MemoryOptimized_M2000`, `FlashOptimized_A250`, `FlashOptimized_A500`, `FlashOptimized_A700`, `FlashOptimized_A1000`, `FlashOptimized_A1500`, `FlashOptimized_A2000`, `FlashOptimized_A4500`.

## Outputs

| Output | Description |
|---|---|
| `hostname` | Cache hostname |
| `port` | TLS port (10000) |
| `primary_access_key` | Access key (sensitive); null when access keys are disabled |
| `auth_token` | Alias for `primary_access_key` |
| `connection_url` | `rediss://:key@host:port`, or `rediss://host:port` when access keys are disabled |
| `access_keys_authentication_enabled` | Whether access-key auth is on |
| `entra_principals` | `{ alias = { object_id, assignment_id } }` for assigned principals |
| `entra_token_scope` | OAuth scope for Entra tokens (`https://redis.azure.com/.default`) |
| `id` | Azure resource ID |

## One-Way Door Decisions

Cannot be changed after creation:
- Name
- `high_availability_enabled`
- `clustering_policy` (changing it recreates the default database and loses data)
- Customer-managed key (fixed at creation)

## Modifiable After Creation

- `sku_name` (scale up within SKU limits)
- `eviction_policy`
- RDB persistence
- Entra principals and access-key authentication
- Tags

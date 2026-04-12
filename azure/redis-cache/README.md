# Azure Cache for Redis Module

Terraform module for provisioning Azure Cache for Redis.

## Features

- Standard and Premium SKU support
- TLS-only access (non-SSL port disabled)
- Optional Private Link access
- Optional clustering and read replicas (Premium SKU)
- Firewall rules for public access mode
- Deletion protection via management lock

## Usage

```hcl
module "cache" {
  source = "./infra/ryvn-cache/azure"

  installation_name   = "my-app-cache"
  environment         = "production"
  resource_group_name = azurerm_resource_group.this.name
  location            = "eastus"

  # SKU
  sku_name = "Standard"
  capacity = 1

  # Maintenance
  patch_day  = "Sunday"
  patch_hour = 4

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
}
```

### Private Link Access

```hcl
module "cache" {
  source = "./infra/ryvn-cache/azure"

  installation_name   = "my-app-cache"
  environment         = "production"
  resource_group_name = azurerm_resource_group.this.name

  sku_name  = "Standard"
  capacity  = 1

  private_endpoint_subnet_id = azurerm_subnet.private_endpoints.id
  private_dns_zone_id        = azurerm_private_dns_zone.redis.id
}
```

## Required Variables

- `installation_name`: Identifier for the cache instance
- `environment`: Environment name
- `resource_group_name`: Azure resource group

## Optional Variables

| Variable | Default | Description |
|---|---|---|
| `location` | `"eastus"` | Azure region |
| `sku_name` | `"Standard"` | `"Basic"`, `"Standard"`, or `"Premium"` |
| `capacity` | `1` | Cache size (0-6 for Basic/Standard, 1-5 for Premium) |
| `redis_version` | `"6"` | Redis major version |
| `private_endpoint_subnet_id` | `null` | Private endpoint subnet ID |
| `private_dns_zone_id` | `null` | Private DNS zone ID for `privatelink.redis.cache.windows.net` |
| `allowed_cidr_blocks` | `[]` | Firewall CIDRs (public mode only) |
| `replicas_per_primary` | `0` | Read replicas (Premium only, 0-3) |
| `shard_count` | `0` | Cluster shards (Premium only, 0-10) |
| `maxmemory_policy` | `"volatile-lru"` | Eviction policy |

## Outputs

| Output | Description |
|---|---|
| `hostname` | Cache hostname |
| `port` | SSL port |
| `primary_access_key` | Access key (sensitive) |
| `connection_url` | Full connection URL `rediss://:key@host:port` |
| `id` | Azure resource ID |

## One-Way Door Decisions

Cannot be changed after creation:
- SKU tier (Basic/Standard/Premium)

## Modifiable After Creation

- Capacity (scale up/down within SKU tier)
- Redis configuration (maxmemory-policy, etc.)
- Replicas and shard count (Premium)
- Maintenance window

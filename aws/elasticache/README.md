# ElastiCache Redis/Valkey Module

Terraform module for provisioning AWS ElastiCache with Redis or Valkey engine.

## Features

- Supports both Redis and Valkey engines
- Configurable replication with read replicas
- Multi-AZ with automatic failover
- Encryption at rest and in transit
- AUTH token support
- Automated snapshots
- SNS notifications

## Usage

```hcl
module "cache" {
  source = "./infra/ryvn-cache/aws"

  installation_name  = "my-app-cache"
  environment        = "production"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = join(",", module.vpc.private_subnets)

  # Engine: "redis" (default) or "valkey"
  engine         = "redis"
  engine_version = "7.1"

  # Instance
  node_type          = "cache.t3.medium"
  num_cache_clusters = 2

  # High Availability (requires num_cache_clusters >= 2)
  multi_az_enabled           = true
  automatic_failover_enabled = true

  # Encryption
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.cache_auth_token

  tags = {
    Environment = "production"
    Project     = "my-application"
  }
}
```

### Minimal (single-node, no TLS)

```hcl
module "cache" {
  source = "./infra/ryvn-cache/aws"

  installation_name  = "my-app-cache"
  environment        = "staging"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = join(",", module.vpc.private_subnets)
}
```

### Valkey

```hcl
module "cache" {
  source = "./infra/ryvn-cache/aws"

  installation_name  = "my-app-cache"
  environment        = "production"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = join(",", module.vpc.private_subnets)

  engine         = "valkey"
  engine_version = "7.2"
  node_type      = "cache.r7g.large"
}
```

## Required Variables

- `installation_name`: Identifier for the replication group
- `environment`: Environment name
- `vpc_id`: VPC ID
- `private_subnet_ids`: Comma-separated subnet IDs

## Optional Variables

| Variable | Default | Description |
|---|---|---|
| `engine` | `"redis"` | `"redis"` or `"valkey"` |
| `engine_version` | `null` (auto) | Engine version (e.g., `"7.1"` for Redis, `"7.2"` for Valkey) |
| `node_type` | `"cache.t3.medium"` | Instance type |
| `num_cache_clusters` | `1` | Number of nodes (>1 for replicas) |
| `port` | `6379` | Cache port |
| `multi_az_enabled` | `false` | Multi-AZ (needs >= 2 nodes) |
| `automatic_failover_enabled` | `false` | Auto-failover (needs >= 2 nodes) |
| `at_rest_encryption_enabled` | `true` | Encrypt data at rest |
| `transit_encryption_enabled` | `false` | Encrypt data in transit (TLS) |
| `auth_token` | `null` | AUTH password (needs TLS enabled) |
| `snapshot_retention_limit` | `7` | Days to keep snapshots (0 = disabled) |

## Outputs

| Output | Description |
|---|---|
| `primary_endpoint` | Primary endpoint address |
| `reader_endpoint` | Reader endpoint (load-balanced across replicas) |
| `port` | Cache port |
| `connection_url` | Full connection URL (`redis://` or `rediss://`) |
| `engine` | Engine used |
| `replication_group_arn` | ARN of the replication group |
| `security_group_id` | Security group ID (for additional ingress rules) |

## One-Way Door Decisions

Cannot be changed after creation:
- VPC / subnet configuration
- At-rest encryption
- Engine type (redis vs valkey)

## Modifiable After Creation

- Node type (causes brief downtime)
- Number of cache clusters
- Engine version (minor upgrades)
- Multi-AZ / failover settings
- Maintenance and snapshot windows
- AUTH token

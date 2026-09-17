# ElastiCache Redis/Valkey Module

Terraform module for provisioning AWS ElastiCache with Redis or Valkey engine.

## Features

- Supports both Redis and Valkey engines
- Configurable replication with read replicas
- Multi-AZ with automatic failover
- Encryption at rest (AWS-managed or customer-managed KMS key) and in transit
- AUTH token support
- IAM authentication (passwordless) with per-login `elasticache:Connect` policies for the workload identity module
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

### IAM Authentication (passwordless)

```hcl
module "cache" {
  source = "./infra/ryvn-cache/aws"

  installation_name  = "my-app-cache"
  environment        = "production"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = join(",", module.vpc.private_subnets)

  engine                     = "valkey"
  transit_encryption_enabled = true
  iam_authentication_enabled = true
}

module "workload_identity" {
  source = "./infra/ryvn-workload-identity/aws"

  role_groups = {
    api = {
      associations = [{ namespace = "app", service_account = "api" }]
      policy_arns  = [module.cache.read_write_iam_policy_arn]
    }
    reports = {
      associations = [{ namespace = "app", service_account = "reports" }]
      policy_arns  = [module.cache.read_only_iam_policy_arn]
    }
  }
}
```

When `iam_authentication_enabled = true` the module:

- Creates three ElastiCache RBAC users with `authentication_mode = iam` and no
  stored secret: `<name>-admin` (`on ~* &* +@all`), `<name>-rw` (everything
  except admin/dangerous commands) and `<name>-ro` (read commands only).
  Usernames and access strings are configurable via `iam_*_username` and
  `iam_*_access_string`.
- Puts them in a user group attached to the replication group. For Redis the
  built-in `default` user (full access, no password) is replaced with a
  disabled one; Valkey disables it automatically.
- Creates one IAM policy per login granting `elasticache:Connect` on the
  replication group and that user only. Attach the ARNs through the workload
  identity module's `role_groups.<group>.policy_arns`.
- Removes the cluster AUTH token: `auth_token` must be null, `auth_token`
  outputs null and `connection_url` contains no credentials.

Clients connect with `user_name` from `iam_users` as the Redis username and a
SigV4 presigned token as the password (see "Authenticating with IAM" in the
ElastiCache user guide for the token format). Tokens are valid for 15 minutes and
connections are dropped after 12 hours, so the client must re-`AUTH`
periodically — most libraries expose a credentials-provider hook for this.

Requirements and caveats:

- `transit_encryption_enabled = true` and Redis 7.0+ or Valkey 7.2+.
- No SQL-style grants are needed: the access strings fully define each
  login's privileges, so nothing has to be created by hand after apply.
- ElastiCache cannot attach a user group to a replication group that still has
  an AUTH token. To migrate an existing token-based cache, first apply with
  the token removed (see `auth_token_update_strategy = DELETE` in the AWS
  docs), then enable IAM.
- Serverless caches are not supported by this module.

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
| `transit_encryption_enabled` | `true` | Encrypt data in transit (TLS) |
| `kms_key_id` | `null` | Customer-managed KMS key ARN for at-rest encryption (needs `at_rest_encryption_enabled`) |
| `auth_token` | `null` | AUTH password (needs TLS enabled; must be null with IAM) |
| `iam_authentication_enabled` | `false` | Replace the AUTH token with IAM RBAC users and `elasticache:Connect` policies |
| `iam_admin_username` / `iam_read_only_username` / `iam_read_write_username` | `<name>-admin` / `<name>-ro` / `<name>-rw` | IAM login names (also the ElastiCache user IDs) |
| `iam_admin_access_string` / `iam_read_only_access_string` / `iam_read_write_access_string` | see `variables.tf` | RBAC access strings per login |
| `snapshot_retention_limit` | `7` | Days to keep snapshots (0 = disabled) |

## Outputs

| Output | Description |
|---|---|
| `primary_endpoint` | Primary endpoint address |
| `reader_endpoint` | Reader endpoint (load-balanced across replicas) |
| `port` | Cache port |
| `connection_url` | Full connection URL (`redis://` or `rediss://`); no credentials when IAM is enabled |
| `auth_token` | AUTH token (sensitive), or null when IAM is enabled |
| `iam_authentication_enabled` | Whether IAM authentication is on |
| `iam_users` | `{admin, read_only, read_write}` → `{user_id, user_name, arn}` |
| `user_group_id` | ElastiCache user group attached to the cache, or null |
| `admin_iam_policy_arn` | `elasticache:Connect` policy for the admin login (empty when IAM is disabled) |
| `read_only_iam_policy_arn` | `elasticache:Connect` policy for the read-only login |
| `read_write_iam_policy_arn` | `elasticache:Connect` policy for the read-write login |
| `engine` | Engine used |
| `replication_group_arn` | ARN of the replication group |
| `security_group_id` | Security group ID (for additional ingress rules) |

## One-Way Door Decisions

Cannot be changed after creation:
- VPC / subnet configuration
- At-rest encryption and its KMS key
- Engine type (redis vs valkey)

## Modifiable After Creation

- Node type (causes brief downtime)
- Number of cache clusters
- Engine version (minor upgrades)
- Multi-AZ / failover settings
- Maintenance and snapshot windows
- AUTH token
- IAM authentication (see migration caveat above)

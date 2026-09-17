# GCP Memorystore for Redis Module

Terraform module for provisioning Google Cloud Memorystore for Redis.

## Features

- BASIC and STANDARD_HA tier support
- AUTH authentication enabled by default (no IAM data-plane auth on this product, see below)
- In-transit encryption (TLS) enabled by default
- Optional customer-managed encryption key (CMEK) for data at rest
- Private-only access via VPC network
- Configurable Redis parameters
- Maintenance window scheduling

## Usage

```hcl
module "cache" {
  source = "./infra/ryvn-cache/gcp"

  installation_name  = "my-app-cache"
  environment        = "production"
  project_id         = var.project_id
  region             = "us-central1"
  authorized_network = google_compute_network.vpc.self_link

  # Compute
  tier           = "STANDARD_HA"
  memory_size_gb = 2

  # Redis version
  redis_version = "7"

  labels = {
    project = "my-application"
  }
}
```

### Minimal

```hcl
module "cache" {
  source = "./infra/ryvn-cache/gcp"

  installation_name  = "my-app-cache"
  environment        = "staging"
  project_id         = var.project_id
  authorized_network = google_compute_network.vpc.self_link
}
```

### With Custom Redis Config

```hcl
module "cache" {
  source = "./infra/ryvn-cache/gcp"

  installation_name  = "my-app-cache"
  environment        = "production"
  project_id         = var.project_id
  authorized_network = google_compute_network.vpc.self_link

  tier           = "STANDARD_HA"
  memory_size_gb = 4

  redis_configs = {
    maxmemory-policy  = "allkeys-lru"
    notify-keyspace-events = "Ex"
  }
}
```

## IAM Authentication (not available)

Memorystore for Redis (`google_redis_instance`, which this module provisions)
has no data-plane IAM authentication: IAM roles such as `roles/redis.editor`
only govern the control plane (creating and managing instances), not Redis
connections. The only client authentication is the instance AUTH string, so
this module keeps `auth_enabled = true` by default and exposes `auth_string`.
Workload identity gives pods a Google service account, but that identity
cannot be used to `AUTH` to the instance.

Passwordless IAM authentication (`roles/redis.dbConnectionUser`, token in the
AUTH position) exists only for Memorystore for Redis Cluster and Memorystore
for Valkey, which are different products (`google_redis_cluster` /
`google_memorystore_instance`) with different networking (Private Service
Connect) and no BASIC tier. Adopting IAM on GCP means moving this module to
one of those resources, which recreates the instance.

## Required Variables

- `installation_name`: Identifier for the Redis instance
- `environment`: Environment name
- `project_id`: GCP project ID
- `authorized_network`: VPC network self_link

## Optional Variables

| Variable | Default | Description |
|---|---|---|
| `region` | `"us-central1"` | GCP region |
| `redis_version` | `"7"` | Redis version (`"6"`, `"7"`, `"7.2"`) |
| `tier` | `"BASIC"` | `"BASIC"` or `"STANDARD_HA"` |
| `memory_size_gb` | `1` | Memory size in GiB (1-300) |
| `connect_mode` | `"DIRECT_PEERING"` | `"DIRECT_PEERING"` or `"PRIVATE_SERVICE_ACCESS"` |
| `auth_enabled` | `true` | Enable Redis AUTH |
| `transit_encryption_enabled` | `true` | Enable TLS |
| `customer_managed_key` | `null` | Cloud KMS key resource name for CMEK (same region as the instance) |
| `redis_configs` | `{}` | Redis configuration parameters |
| `maintenance_day` | `"SUNDAY"` | Maintenance day |
| `maintenance_hour` | `4` | Maintenance hour (UTC) |

## Outputs

| Output | Description |
|---|---|
| `host` | Redis instance IP address |
| `port` | Redis port |
| `auth_string` | AUTH string (sensitive) |
| `connection_url` | Full connection URL `redis(s)://:auth@host:port` |
| `server_ca_certs` | TLS CA certificates (sensitive) |
| `id` | Memorystore instance ID |

## One-Way Door Decisions

Cannot be changed after creation:
- VPC network (authorized_network)
- Connect mode
- Region
- Customer-managed encryption key

## Modifiable After Creation

- Memory size (scale up/down)
- Redis configuration parameters
- Maintenance window
- AUTH and TLS settings

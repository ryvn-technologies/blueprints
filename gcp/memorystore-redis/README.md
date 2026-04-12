# GCP Memorystore for Redis Module

Terraform module for provisioning Google Cloud Memorystore for Redis.

## Features

- BASIC and STANDARD_HA tier support
- AUTH authentication enabled by default
- In-transit encryption (TLS) enabled by default
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

## Modifiable After Creation

- Memory size (scale up/down)
- Redis configuration parameters
- Maintenance window
- AUTH and TLS settings

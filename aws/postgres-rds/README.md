# PostgreSQL RDS Module

Provisions a PostgreSQL RDS instance with encryption, automated backups, monitoring, and optional high availability.

## Usage

```hcl
module "postgres" {
  source = "./infra/ryvn-postgres/aws"

  name_prefix       = "my-app"
  environment       = "production"
  vpc_id            = "vpc-abc123"
  subnet_ids        = "subnet-1,subnet-2"
  database_username = "postgres"
  database_password = var.database_password
}
```

## What's Included

- **Storage**: GP3 with autoscaling, encrypted at rest
- **Backups**: Automated daily backups (7-day retention), final snapshot on destroy
- **Monitoring**: Performance Insights, Enhanced Monitoring (60s), CloudWatch log exports (postgresql, upgrade)
- **Security**: VPC security group, deletion protection enabled by default
- **HA**: Optional multi-AZ deployment

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `name_prefix` | Prefix for instance name (random suffix appended) | required |
| `environment` | Environment name | required |
| `vpc_id` | VPC ID | required |
| `subnet_ids` | Comma-separated subnet IDs | required |
| `database_username` | Master username (immutable after creation) | required |
| `database_password` | Master password (min 8 chars) | required |
| `engine_version` | PostgreSQL version (13-17) | `"16"` |
| `instance_class` | RDS instance class | `"db.t3.medium"` |
| `storage_gb` | Initial storage in GiB (can only increase) | `20` |
| `max_storage_gb` | Max storage for autoscaling (0 to disable) | `100` |
| `high_availability` | Multi-AZ deployment | `false` |
| `deletion_protection` | Prevent accidental deletion | `true` |
| `database_name` | Default database to create | `null` |
| `backup_retention_days` | Automated backup retention | `7` |
| `allowed_cidr_blocks` | CIDRs allowed to access the database | `[]` (VPC only) |
| `publicly_accessible` | Allow public access | `false` |
| `performance_insights_enabled` | Enable Performance Insights | `true` |
| `performance_insights_retention_period` | PI retention in days | `7` |
| `monitoring_interval` | Enhanced Monitoring interval (0 to disable) | `60` |
| `enabled_cloudwatch_logs_exports` | Log types to export | `["postgresql", "upgrade"]` |
| `tags` | Tags for all resources | `{}` |

## Outputs

| Name | Description |
|------|-------------|
| `endpoint` | Connection endpoint (host:port) |
| `host` | Database hostname |
| `port` | Database port |
| `database_name` | Default database name |
| `username` | Master username |
| `arn` | RDS instance ARN |
| `id` | RDS instance identifier |
| `name` | Generated instance name |

## One-Way Decisions

These cannot be changed after creation: VPC/subnets, master username, port, storage encryption, storage type (GP3). Storage can only be increased, never decreased.

## Future Additions

- Secrets Manager integration (`manage_master_user_password`) to remove passwords from Terraform state
- IAM database authentication
- Read replica support
- Restore from snapshot / point-in-time recovery
- Provisioned IOPS and throughput tuning
- `apply_immediately` control
- Auto minor version upgrade control
- Blue/Green deployment support for major version upgrades
- SNS event subscriptions for failover and maintenance alerts
- CA certificate pinning

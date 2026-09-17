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

- **Storage**: GP3 with autoscaling, encrypted at rest (AWS-managed key by default, or a customer-managed KMS key via `kms_key_id`)
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
| `database_password` | Master password, required unless `manage_master_user_password` is enabled; must be null when enabled | `null` |
| `manage_master_user_password` | Let RDS generate and manage the master password in Secrets Manager | `false` |
| `iam_database_authentication_enabled` | Enable IAM authentication and create separate database-login policies | `false` |
| `iam_read_only_username` | Existing or separately provisioned read-only login to authorize | `null` |
| `iam_read_write_username` | Existing or separately provisioned read-write login to authorize | `null` |
| `engine_version` | PostgreSQL version (13-17) | `"16"` |
| `instance_class` | RDS instance class | `"db.t3.medium"` |
| `storage_gb` | Initial storage in GiB (can only increase) | `20` |
| `max_storage_gb` | Max storage for autoscaling (0 to disable) | `100` |
| `high_availability` | Multi-AZ deployment | `false` |
| `kms_key_id` | Customer-managed KMS key ARN for storage and Performance Insights encryption | `null` (AWS-managed key) |
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
| `password` | Caller-provided master password; null when RDS manages the password |
| `connection_string` | Password-based connection string; null when IAM or RDS-managed passwords are enabled |
| `master_user_secret_arn` | RDS-managed master password secret ARN; null when password management is disabled |
| `master_secret_read_policy_arn` | Managed policy allowing retrieval of the master password secret; empty when password management is disabled |
| `arn` | RDS instance ARN |
| `id` | RDS instance identifier |
| `name` | Generated instance name |
| `resource_id` | Immutable RDS resource ID used in IAM database-login ARNs |
| `region` | AWS region for signing database authentication tokens |
| `master_iam_policy_arn` | Managed policy granting access as the master login; empty when IAM is disabled |
| `read_only_iam_policy_arn` | Managed policy granting access as `iam_read_only_username`; empty when IAM or that login is disabled |
| `read_write_iam_policy_arn` | Managed policy granting access as `iam_read_write_username`; empty when IAM or that login is disabled |

## Managed master password

Set `manage_master_user_password = true` and `database_password = null` to let RDS
generate and manage the master password in Secrets Manager. This setting is
independent of IAM authentication. When it is false, supply `database_password`.

The module exposes `master_user_secret_arn` without reading the secret value into
Terraform state. The `password` and `connection_string` outputs are null when RDS
manages the password. Consumers that use password authentication must retrieve it
from Secrets Manager. Switching an existing instance to Secrets Manager does not
remove old passwords from prior state versions.

It also creates `master_secret_read_policy_arn`, granting only
`secretsmanager:GetSecretValue` on that secret. Attach it to the IAM role of an
administrator or bootstrap identity. This policy exists
whenever password management is enabled, independently of IAM database login.

## Advanced IAM authentication

IAM is disabled by default. Enabling it prepares the RDS instance and publishes
managed IAM policies. It does not create PostgreSQL users, change their SQL
privileges or authentication method, create workload identities, or attach policies
to roles. The Postgres blueprint and user-provisioning job continue to use passwords.

For IAM with an RDS-managed master password, add these inputs:

```hcl
iam_database_authentication_enabled = true
manage_master_user_password         = true
database_password                   = null
iam_read_only_username              = "app_ro"
iam_read_write_username             = "app_rw"
```

IAM also works with a caller-provided master password. Leave
`manage_master_user_password = false` and supply `database_password` in that case.

The master policy is created whenever IAM is enabled. Application policies are
created only for the supplied usernames; leave a username null to omit its policy.
Each policy allows only `rds-db:connect` on one login:

```text
arn:<partition>:rds-db:<region>:<account>:dbuser:<resource_id>/<username>
```

The usernames must be distinct and use 1-63 letters, digits or underscores,
starting with a letter or underscore. Read-only and read-write describe the
intended SQL users. The IAM policies themselves only authorize login; PostgreSQL
grants determine what each user can do. No monitoring-user IAM policy is created.

### Attach policies to workload roles

Attach the appropriate policy ARN to the IAM role that the workload's Kubernetes
service account assumes (for example through an EKS Pod Identity association):

```hcl
resource "aws_iam_role_policy_attachment" "api_database" {
  role       = aws_iam_role.api.name
  policy_arn = module.postgres.read_write_iam_policy_arn
}
```

Use `read_only_iam_policy_arn` for read-only workloads. Attach
`master_iam_policy_arn` only to identities that should have the master user's SQL
privileges. Because these are plain managed policies, a workload role can combine
database access with policies from other resources.

### Bootstrap the master login

For a user-owned bootstrap job, enable both IAM authentication and managed
passwords, then attach both `master_secret_read_policy_arn` (initial password) and
`master_iam_policy_arn` (master IAM login) to the job's IAM role.

Create the Kubernetes service account and configure the job with
`serviceAccountName: postgres-bootstrap` in the `production` namespace. The job
needs AWS CLI, `jq`, `psql`, and network access to RDS and the AWS APIs. Mount the
[RDS CA bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)
and supply these environment variables from the module outputs:

| Job environment variable | Value |
|--------------------------|-------|
| `AWS_REGION` | `module.postgres.region` |
| `PGHOST` | `module.postgres.host` |
| `PGPORT` | `module.postgres.port` |
| `PGDATABASE` | `module.postgres.database_name` |
| `PGUSER` | `module.postgres.username` |
| `MASTER_SECRET_ARN` | `module.postgres.master_user_secret_arn` |
| `PGSSLROOTCERT` | Path to the mounted RDS CA bundle |

Once the RDS settings and identity permissions have taken effect, run this Bash
snippet once to convert the master login. It reads the password at runtime,
grants `rds_iam`, then opens a fresh connection using an IAM token:

```bash
(
  set -euo pipefail
  set +x
  : "${AWS_REGION:?}" "${PGHOST:?}" "${PGPORT:?}" "${PGDATABASE:?}" \
    "${PGUSER:?}" "${MASTER_SECRET_ARN:?}" "${PGSSLROOTCERT:?}"
  export PGSSLMODE=verify-full

  PGPASSWORD="$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" --secret-id "$MASTER_SECRET_ARN" \
    --query SecretString --output text | jq -er '.password')"
  export PGPASSWORD
  psql -X --no-password --set=ON_ERROR_STOP=1 \
    --set=master_username="$PGUSER" <<'SQL'
GRANT rds_iam TO :"master_username";
SQL

  PGPASSWORD="$(aws rds generate-db-auth-token \
    --hostname "$PGHOST" --port "$PGPORT" \
    --region "$AWS_REGION" --username "$PGUSER")"
  psql -X --no-password --set=ON_ERROR_STOP=1 \
    --command='SELECT current_user;'
)
```

After the grant succeeds, new connections for this login require IAM. If the
token connection fails, fix the IAM permissions or client configuration and retry
only the token connection. Repeating the initial password step will fail. An
already-converted master should skip the password and grant steps entirely.

After verifying IAM access, detach `master_secret_read_policy_arn` from the
bootstrap role. Keep `master_iam_policy_arn` for subsequent administration through
IAM. Application identities should receive only their own database-login policy.
Creating application users and assigning SQL privileges remains part of your
provisioning workflow.

### Configure PostgreSQL and clients

After the RDS setting has taken effect, connect as an administrator and grant
`rds_iam` to the intended logins. Create any missing users and apply their SQL
database, schema, table, and default privileges separately. For existing users:

```sql
GRANT rds_iam TO app_ro, app_rw;
```

For the initial administrator connection, use the caller-provided password or,
when `manage_master_user_password` is enabled, retrieve the RDS-managed secret
identified by `master_user_secret_arn`. Reading it requires
`secretsmanager:GetSecretValue`.

The master can also use IAM by granting `rds_iam` to `database_username`, for
example `GRANT rds_iam TO postgres`. Configure and verify an authorized administrator
identity first. IAM takes precedence over passwords for any user with `rds_iam`.
In particular, converting the master used by the current Postgres blueprint breaks
its password-based user-provisioning job. Advanced callers must provide their own
IAM-capable provisioning workflow before converting that account.

Clients must obtain AWS credentials and sign a token using the actual RDS `host`,
`port`, `region`, and exact database username. Supply it as the connection password
over TLS with certificate verification, such as `sslmode=verify-full` and the RDS
CA bundle. Tokens expire after 15 minutes; obtain a valid token for every new
physical connection, including pool reconnects. Existing sessions are unaffected
by token expiry. Network access to the database is still required.

The `connection_string` output is null when IAM is enabled. The `password` output
follows `manage_master_user_password` and can still expose a caller-provided
password, but that password cannot authenticate a login switched to IAM. Keep
tokens out of Terraform state and durable application configuration.

To return to passwords, use an authorized database session to revoke `rds_iam`.
For an RDS-managed master password, use the current value from Secrets Manager;
set passwords for other converted logins as needed. Verify password access, then
detach the policies from the workload roles before disabling
this module's IAM setting. Disabling IAM deletes the managed policies, and AWS rejects
deleting policies that are still attached. Detach an application policy before
setting its username to null for the same reason. Monitoring can continue using
its existing password throughout.

Disabling IAM does not change password management. If you separately disable
`manage_master_user_password`, supply `database_password`; RDS stops managing the
master password and deletes its managed secret. Detach `master_secret_read_policy_arn`
from all identities before disabling password management, because this also
deletes the secret-read policy.

See the AWS documentation for [database users](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.DBAccounts.html),
[IAM policies](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.IAMPolicy.html),
[PostgreSQL connections](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.Connecting.AWSCLI.PostgreSQL.html),
and [retrieving secrets](https://docs.aws.amazon.com/secretsmanager/latest/userguide/retrieving-secrets_cli.html).

### Validation

Run `terraform init -backend=false`, `terraform validate`, and `terraform test`
from this directory. The module requires Terraform 1.9 or later for input
validation across variables. The tests require Terraform 1.11 or later and use
mock providers; they do not connect to AWS or validate live RDS authentication.

## One-Way Decisions

These cannot be changed after creation: VPC/subnets, master username, port, storage encryption, KMS key, storage type (GP3). Storage can only be increased, never decreased.

## Customer-Managed Keys

Set `kms_key_id` to a KMS key ARN to encrypt storage, snapshots, and Performance Insights data with your own key. The key must live in the same region as the instance. Its key policy has to let the provisioning role call `kms:DescribeKey` and `kms:CreateGrant`; RDS creates a grant on the key for the instance. Switching an existing instance to a different key forces replacement.

## Future Additions

- Read replica support
- Restore from snapshot / point-in-time recovery
- Provisioned IOPS and throughput tuning
- `apply_immediately` control
- Auto minor version upgrade control
- Blue/Green deployment support for major version upgrades
- SNS event subscriptions for failover and maintenance alerts
- CA certificate pinning

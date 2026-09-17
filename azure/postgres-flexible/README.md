# Azure PostgreSQL Flexible Server

Provisions a PostgreSQL Flexible Server with optional private networking, high
availability, and customer-managed encryption. Requires Terraform 1.9 or later.

## Password authentication

Password authentication remains the default:

```hcl
module "postgres" {
  source = "./infra/ryvn-postgres/azure"

  name_prefix         = "my-app"
  environment         = "production"
  resource_group_name = "my-app-production"
  database_username   = "pgadmin"
  database_password   = var.database_password
}
```

## Direct workload identity authentication

Advanced Terraform consumers can enable Microsoft Entra authentication and
register their own bootstrap identity as a database administrator. That identity
can use an Entra token for its first database connection. No initial password,
Key Vault secret, or Ryvn user-provisioner job is needed.

The consumer owns the managed identity and its workload federation. The database
module registers the identity as an administrator; it does not create workload
identities, configure Kubernetes service accounts, or manage application roles
and SQL grants. The existing Postgres blueprint continues to use its default
password authentication.

This example creates a new Entra-only server for an AKS bootstrap workload:

```hcl
resource "azurerm_user_assigned_identity" "postgres_bootstrap" {
  name                = "postgres-bootstrap"
  location            = var.location
  resource_group_name = var.resource_group_name
}

resource "azurerm_federated_identity_credential" "postgres_bootstrap" {
  name                = "postgres-bootstrap"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.postgres_bootstrap.id
  issuer              = var.aks_oidc_issuer_url
  audience            = ["api://AzureADTokenExchange"]
  subject             = "system:serviceaccount:production:postgres-bootstrap"
}

module "postgres" {
  source = "./infra/ryvn-postgres/azure"

  name_prefix         = "my-app"
  environment         = "production"
  location            = var.location
  resource_group_name = var.resource_group_name
  database_name       = "appdb"

  delegated_subnet_id = var.postgres_subnet_id
  private_dns_zone_id = var.postgres_private_dns_zone_id

  entra_authentication_enabled    = true
  password_authentication_enabled = false
  entra_tenant_id                 = azurerm_user_assigned_identity.postgres_bootstrap.tenant_id
  entra_administrators = {
    bootstrap = {
      object_id      = azurerm_user_assigned_identity.postgres_bootstrap.principal_id
      principal_name = azurerm_user_assigned_identity.postgres_bootstrap.name
      principal_type = "ServicePrincipal"
    }
  }
}
```

AKS must have its OIDC issuer and workload identity enabled. Create the
`postgres-bootstrap` service account in namespace `production`, annotate it with
`azure.workload.identity/client-id` set to the managed identity's `client_id`,
and run the bootstrap pod with that service account and pod label
`azure.workload.identity/use: "true"`. The federation subject must match the
namespace and service account exactly.

Use the identity's **principal ID** for `object_id`, and its **client ID** for
workload authentication. `ServicePrincipal` is the administrator type for a
managed identity. The server's optional encryption identity is independent of
these database login identities.

## Authentication inputs and outputs

| Input | Default | Meaning |
| --- | --- | --- |
| `entra_authentication_enabled` | `false` | Enable Microsoft Entra authentication. |
| `password_authentication_enabled` | `true` | Allow local PostgreSQL password authentication. At least one authentication method must be enabled. |
| `entra_tenant_id` | `null` | Tenant UUID, required with Entra authentication and omitted otherwise. |
| `entra_administrators` | `{}` | Map of stable aliases to `object_id`, `principal_name`, and `principal_type`. Requires at least one entry when Entra is enabled; must be empty otherwise. Types are `User`, `Group`, or `ServicePrincipal`. |
| `database_username` | `null` | Local administrator login, required with password authentication. Omit for a new Entra-only server. |
| `database_password` | `null` | Local administrator password, required with password authentication. Omit for a new Entra-only server. |

Each administrator entry grants elevated database privileges. Use a dedicated
bootstrap identity or operations group. Create ordinary application roles through
the database configuration step below.

| Output | Meaning |
| --- | --- |
| `host`, `fqdn`, `endpoint`, `port` | Database connection address. |
| `name`, `id` | Server name and Azure resource ID. |
| `database_name` | Requested application database, or null when none was requested. |
| `username`, `password`, `connection_string` | Local password credentials; null when password authentication is disabled. Retained in mixed authentication mode. |
| `entra_tenant_id` | Trusted tenant UUID, or null when Entra is disabled. |
| `entra_administrators` | Provisioned administrators keyed by input alias, with `object_id`, `principal_name`, and `principal_type`. |

For the example above, use
`module.postgres.entra_administrators["bootstrap"].principal_name` as the
PostgreSQL username. These outputs depend on administrator provisioning. Acquire
tokens at runtime; the module does not generate or store them.

## Bootstrap and application permissions

After Terraform apply completes and federation has propagated, the bootstrap
workload can use Azure Identity's `DefaultAzureCredential` or
`WorkloadIdentityCredential` to request the public-cloud scope
`https://ossrdbms-aad.database.windows.net/.default`. Connect to `host` on port
5432 using the administrator's `principal_name` and the token as the password.
Use TLS with certificate verification, for example `sslmode=verify-full` with
the appropriate trusted CA certificates.

Connect to the built-in `postgres` database to create an application identity
mapping. Run this as an Entra administrator, substituting the application's
managed identity principal ID:

```sql
SELECT * FROM pg_catalog.pgaadauth_create_principal_with_oid(
  'app_rw', '<application-principal-id>', 'service', false, false
);
GRANT CONNECT ON DATABASE appdb TO app_rw;
```

This is a one-time role-creation example. For an existing role, inspect its
mapping or manage its `pgaadauth` security label instead of rerunning the create
function. Apply the application's schema, table, and sequence grants in `appdb`
with an account that owns those objects or has grant authority. Configure
default privileges for the role that creates future objects, usually the
migration role. The name `app_rw` does not confer write permissions.

A caller-owned Terraform database stage can instead use `cyrilgdn/postgresql`
with `azure_identity_auth = true`, `azure_tenant_id`, and `superuser = false`.
Connect as the Entra administrator to manage `postgresql_role`,
`postgresql_security_label`, and grants. The security label for a workload role
uses `label_provider = "pgaadauth"` and
`label = "aadauth,oid=<application-principal-id>,type=service"`. Omit the `admin`
flag for ordinary application identities. Run this stage after infrastructure
provisioning, from a runner with database network access and credentials for the
registered administrator.

Applications authenticate the same way with their own mapped role name and
identity. Azure RBAC assignments do not replace PostgreSQL role mappings and
SQL grants. Connection pools need a valid token for every new physical
connection; use token expiry and a refresh callback instead of a permanent
connection string containing a startup token.

## Existing servers and networking

To add Entra to an existing password deployment, retain `database_username` and
`database_password`, leave `password_authentication_enabled = true`, and supply
the Entra inputs. Enabling Entra authentication restarts the server.

For a new Entra-only server, omit both local credentials. Migrating an existing
server to Entra-only is a separate operation: first configure and verify Entra
administrator access, then review the Terraform plan before disabling passwords.
Changing an existing administrator login can replace the server. The module
passes local credentials through explicitly and does not automatically clear
them when the authentication setting changes. AzureRM treats absent credentials
and retained credentials differently during creation and updates; verify the
result with your pinned provider before applying. Do not apply a replacement
plan to perform an authentication migration.

Before disabling Entra, establish password-based administration and migrate
dependent clients. Removing an administrator revokes that identity's bootstrap
access. An inherited Azure management lock can block administrator deletion;
remove the lock deliberately before making that change.

The bootstrap runner and applications need network access to PostgreSQL. With
private VNet integration, allow the required outbound `AzureActiveDirectory`
traffic and ensure custom DNS resolves `login.microsoftonline.com` and
`graph.microsoft.com`. Entra authentication does not open firewall rules.

## Validation and references

Run `terraform init -backend=false`, `terraform validate`, and `terraform test`
from this directory. Tests use mock AzureRM and random providers and do not
contact Azure. They cover defaults, Entra-only and mixed authentication, and
invalid authentication configuration. Live token login, SQL grants, and
existing-server migration must be verified against an Azure deployment.

- [AzureRM server authentication](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.68.0/website/docs/r/postgresql_flexible_server.html.markdown)
- [AzureRM Entra administrator](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.68.0/website/docs/r/postgresql_flexible_server_active_directory_administrator.html.markdown)
- [Microsoft Entra authentication and network requirements](https://learn.microsoft.com/en-us/azure/postgresql/security/security-entra-configure)
- [PostgreSQL role mappings](https://learn.microsoft.com/en-us/azure/postgresql/security/security-manage-entra-users)
- [AKS workload identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Terraform PostgreSQL authentication](https://github.com/cyrilgdn/terraform-provider-postgresql/blob/v1.26.0/website/docs/index.html.markdown)
- [Terraform PostgreSQL security labels](https://github.com/cyrilgdn/terraform-provider-postgresql/blob/v1.26.0/website/docs/r/postgresql_security_label.html.markdown)

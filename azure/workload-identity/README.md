# Workload Identity Module (Azure)

Gives Kubernetes workloads an Azure identity without static credentials. Each role group becomes one user-assigned managed identity, federated to the ServiceAccounts listed under it, with the group's role assignments applied. Each assignment is a role definition at a scope, the same two arguments as `azurerm_role_assignment`. Resource modules (containers, queues, vaults) expose the scope and role they grant access with (for example the bucket module's `role_assignment_scope` and `role_definition_name`); pass those, or any scope and role of your own, into `role_assignments`. The module never touches ServiceAccounts, pods, or the resources themselves.

## Usage

```hcl
module "workload_identity" {
  source = "./infra/ryvn-workload-identity/azure"

  name_prefix         = "prod-azure"
  environment         = "production"
  location            = "eastus"
  resource_group_name = "ryvn-prod-azure"
  oidc_issuer_url     = "https://eastus.oic.prod-aks.azure.com/<tenant>/<cluster>/"

  role_groups = {
    app = {
      associations = {
        api = {
          namespace       = "prod-azure"
          service_account = "api"
        }
        worker = {
          namespace       = "prod-azure"
          service_account = "worker"
        }
      }
      role_assignments = {
        media = {
          scope                = module.media_bucket.role_assignment_scope
          role_definition_name = module.media_bucket.role_definition_name
        }
        secrets = {
          scope                = azurerm_key_vault.app.id
          role_definition_name = "Key Vault Secrets User"
        }
      }
    }
  }
}
```

In a Ryvn blueprint, resolve the subjects from the installations themselves rather than typing names:

```yaml
location:            '{{ .ryvn.env.state.resource_group.location }}'
resource_group_name: '{{ .ryvn.env.state.resource_group.name }}'
oidc_issuer_url:     '{{ .ryvn.env.state.cluster.oidc_issuer_url }}'
role_groups:
  app:
    associations:
      worker:
        namespace:          '{{ (serviceInstallation "worker").namespace }}'
        service_account:    '{{ (serviceInstallation "worker").name }}'
    role_assignments:
      media:
        scope:                '{{ (blueprintInstallation "media").outputs.roleAssignmentScope }}'
        role_definition_name: '{{ (blueprintInstallation "media").outputs.roleDefinitionName }}'
```

Ryvn's web-server and job charts name the ServiceAccount after the installation, so the installation name is the ServiceAccount name.

## Wiring the workload

Unlike AWS and GCP, Azure delivers the token through a webhook that only acts on labelled pods. Each service in a group sets, in its own chart values:

```yaml
serviceAccount:
  annotations:
    azure.workload.identity/client-id: '{{ (serviceInstallation "app-identity").outputs.client_ids.app }}'
    azure.workload.identity/tenant-id: '{{ (serviceInstallation "app-identity").outputs.tenant_id }}'
podLabels:
  azure.workload.identity/use: "true"
```

Ryvn's charts pass `serviceAccount.annotations` to both the main and the pre-deploy ServiceAccount, so associate the `-pre-deploy` ServiceAccount too when the hook needs access. Pods must restart after the annotation changes; Ryvn's redeploy on output change handles that.

## What's Included

- **Managed identity per group**: named `<name_prefix>-<role_name>` in the given resource group.
- **Federated credentials**: one per subject, issuer set to the cluster's OIDC issuer, subject `system:serviceaccount:<namespace>:<service account>`, audience `api://AzureADTokenExchange`. Ryvn's pre-deploy hook runs as `<service_account>-pre-deploy`; list it as its own association when the hook needs the same access.
- **Role assignments**: every entry in `role_assignments` (`{ scope, role_definition_name }`) assigned to the group's identity. Keys are yours; they only name the assignment in state, so keep them stable.

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `name_prefix` | Prefix for identity and credential names, typically the environment name | required |
| `environment` | Environment name, applied as a tag | required |
| `location` | Region for the identities | required |
| `resource_group_name` | Resource group for identities and credentials | required |
| `oidc_issuer_url` | AKS OIDC issuer URL | required |
| `role_groups` | Map of groups; see the shape above | required |
| `tags` | Tags for all resources | `{}` |

## Outputs

| Name | Description |
|------|-------------|
| `identities` | `{id, client_id, principal_id, tenant_id}` per group |
| `client_ids` | Client ID per group, for the ServiceAccount annotation |
| `tenant_id` | Tenant ID, for the ServiceAccount annotation |
| `principals` | `[principal ID]` per group. Same output shape as the AWS and GCP modules |
| `federated_credential_ids` | Federated credential ID per subject |

## Prerequisites

- The AKS cluster has the OIDC issuer and workload identity enabled. Ryvn-provisioned clusters have both.
- The identity running Terraform can create managed identities and federated credentials, and holds `Microsoft.Authorization/roleAssignments/write` at the granted scopes. `Contributor` alone cannot write role assignments.

## Notes

- **One group per ServiceAccount.** The client-id annotation holds a single value, so a ServiceAccount belongs to exactly one group. The variable validation rejects a namespace/ServiceAccount pair that appears more than once.
- **Assignments live on the identity.** Adding a resource means adding one more entry to `role_assignments`; the identity, credentials, and pods do not change. Anything not expressible here can be assigned to `principals.<group>` outside the module.
- **Credential limit.** Azure allows 20 federated credentials per managed identity; the variable validation enforces it.
- **No wildcards.** Federated credential subjects are exact matches, and a mismatch surfaces at token exchange, not at creation.
- **Propagation.** New credentials and assignments take a few seconds to become effective.

# Provisioner permissions

Azure RBAC for the identity that provisions, updates and deprovisions a Ryvn AKS
environment with this module. The counterparts live in
`infra/gke-provision/permissions/` (GCP) and `infra/aws-provision-karpenter/permissions/` (AWS).

| File | Purpose |
|------|---------|
| `provisioner-role.json` | Custom role `ryvn-aks-provision-<sub8>` (91 actions, including explicit Application Gateway ingress, managed egress and control-plane logging permissions). The former `ryvn-aks-provision` definition with `actions: ["*"]` is left in place for existing environments |
| `permissions.go` | Embeds the role so the orchestrator can serve it (same layout as `infra/gke-provision/permissions`) |

## Identity model

The role is granted at subscription scope to one principal per subscription:

- **Credential-less (GCP-rooted hub).** A user-assigned managed identity with a federated
  identity credential trusting the hub's Google service account: issuer
  `https://accounts.google.com`, subject `<unique ID of the hub service account>`, audience
  `api://AzureADTokenExchange`. Terraform authenticates with `ARM_USE_OIDC=true` and the
  hub's Google ID token as the client assertion; no secret exists on either side and no
  Entra application registration is required.
- **Client secret (AWS-rooted hub, current default).** A service principal
  `ryvn-provisioner-<sub8>` created with
  `az ad sp create-for-rbac --role ryvn-aks-provision-<sub8> --scopes /subscriptions/<id>`.
  One app per subscription: `create-for-rbac` resets the passwords of an existing app with
  the same display name, so a shared name would revoke another subscription's secret.

Authorization is identical in both cases: only the way the token is obtained differs, so
the role is not widened for federation.

The runtime identity is different: after bootstrap the in-cluster agent runs as the
`ryvn-agent-<env>` managed identity with the role defined in `agent.tf`. That role is
created *by* the provisioner and is out of scope here (see "IAM-write actions").

## How the role was derived

The original 50-action role was live-validated in a scratch subscription with a fresh
managed identity holding only that role (no Owner, Contributor, User Access Administrator,
or the old wildcard role), federated
to a Google service account exactly as above:

1. `terraform apply` of this module (37 resources) with `cluster_bootstrap_perms = true`.
2. Agent bootstrap over the cluster API as the same identity: namespace, Secret,
   ServiceAccount, ClusterRole/ClusterRoleBinding, RoleBinding, Helm release.
3. A second `terraform apply` (no changes) to cover every provider `Read`.
4. `terraform destroy`, then a sweep for leftovers.

Two passes. The first, with a wider 68-action candidate, hit a single `AuthorizationFailed`
(`managedClusters/listClusterAdminCredential/action`, from the provider reading
`kube_admin_config`); the module now disables local accounts, which removes that provider
call and the action with it. The second pass dropped the unobserved reads and ran the
committed role: the only failure was `LinkedAuthorizationFailed` creating private DNS zone
VNet links without `Microsoft.Network/virtualNetworks/join/action`, which was added, after
which apply, bootstrap, no-op re-apply and destroy all completed. Azure Activity Log does
not record successful reads, so the read actions that remain are justified by the provider's
code paths (a resource's `Read` after every create, plus refresh on re-apply) rather than by
log entries.

Managed egress adds explicit firewall/policy, route, public-IP and diagnostics
permissions to that baseline. Round 7 validated firewall behavior using the fixture
identity; it does not establish the expanded role's least-privilege E2E coverage.
Validate the real provisioner identity in the new/existing Ryvn E2E rollout;
do not substitute administrator credentials for that check.

## What the provisioner does

| Step | Resources | Actions |
|------|-----------|---------|
| Provider bootstrap | subscription, locations (`Azure/regions` module), provider metadata | `Microsoft.Resources/subscriptions/read`, `subscriptions/locations/read`, `providers/read` |
| Resource group | `ryvn-rg-<env>` | `Microsoft.Resources/subscriptions/resourceGroups/read|write|delete` |
| Network | VNet (or carve in an existing one), node/appgw/privatelink/postgres subnets, route table association, AKS egress IP lookup | `Microsoft.Network/virtualNetworks/*` (read/write/delete), `virtualNetworks/join/action` (private DNS VNet links), `virtualNetworks/subnets/*` (read/write/delete/join), `routeTables/read|join`, `publicIPAddresses/read` |
| Managed egress | Firewall, policies, rule collections, public IP and UDRs | Explicit `azureFirewalls`, `firewallPolicies`, `firewallPolicies/ruleCollectionGroups` read/write/delete; policy/public-IP join; route-table/route read/write/delete; public-IP write/delete |
| Application Gateway ingress | Standard_v2 gateway, public IP, dedicated subnets | `Microsoft.Network/applicationGateways/read|write|delete|start/action|stop/action`; existing public-IP/subnet read/write/delete/join |
| Ingress security | NSG with inline rules, subnet association | `Microsoft.Network/networkSecurityGroups/read|write|delete|join/action`; existing subnet read/write |
| Network operation polling | asynchronous gateway, NSG, subnet and public-IP operations | `Microsoft.Network/locations/operations/read`, `locations/operationResults/read` |
| Egress diagnostics | Log Analytics workspace and firewall diagnostic setting | `Microsoft.Insights/diagnosticSettings/read|write|delete`, `Microsoft.OperationalInsights/workspaces/read|write|delete|sharedKeys/action` |
| DNS | public zone, private zones for internal domain, PostgreSQL and Redis, VNet links | `Microsoft.Network/dnszones/read|write|delete`, `dnszones/*/read` (SOA read-back), `privateDnsZones/read|write|delete`, `privateDnsZones/*/read`, `privateDnsZones/virtualNetworkLinks/read|write|delete` |
| Cluster | AKS with Azure RBAC, workload identity, two node pools | `Microsoft.ContainerService/managedClusters/read|write|delete`, `managedClusters/agentPools/read|write|delete`, `managedClusters/maintenanceConfigurations/read|write|delete` (node OS and auto-upgrade planned maintenance windows), `managedClusters/listClusterUserCredential/action` (called by `azurerm_kubernetes_cluster` on every read), `locations/operations/read`, `locations/operationresults/read` (long-running operation polling) |
| Control-plane logs | Log Analytics workspace `log-aks-<env>`, diagnostic setting on the cluster (`logging.tf`) | `Microsoft.OperationalInsights/workspaces/read|write|delete`, `workspaces/sharedKeys/action` (diagnostic destination attachment), `deletedworkspaces/read` (the provider lists soft-deleted workspaces before create), `Microsoft.Insights/diagnosticSettings/read|write|delete` |
| Identities | ryvn-agent, external-dns (public and private) and cert-manager identities with federated credentials; kubelet identity assignment | `Microsoft.ManagedIdentity/userAssignedIdentities/read|write|delete|assign/action`, `userAssignedIdentities/federatedIdentityCredentials/read|write|delete` |
| Roles and assignments | agent custom role; Network Contributor / DNS Zone Contributor / Private DNS Zone Contributor / AKS RBAC Cluster Admin assignments | `Microsoft.Authorization/roleDefinitions/read|write|delete`, `roleAssignments/read|write|delete` |
| Agent bootstrap (hub) | Kubernetes objects over the API server | none: authorised by the module's `Azure Kubernetes Service RBAC Cluster Admin` assignment, evaluated by Azure RBAC for Kubernetes; no `dataActions` |
| Teardown | the same set in reverse | the delete actions in each group |

Not needed and deliberately absent: `Microsoft.Resources/deployments/*` (no ARM templates),
resource provider registration (`resource_provider_registrations = "none"`),
`Microsoft.Compute/*`, `Microsoft.Storage/*`, `Microsoft.KeyVault/*`,
workspace query actions or `dataActions`, `Microsoft.Insights/diagnosticSettingsCategories/*`,
`Microsoft.Authorization/locks/*`, `Microsoft.Authorization/policyAssignments/*`, or
application DNS record-set writes. ExternalDNS uses its existing separate identity.

### Application Gateway permission audit

The [Microsoft.Network operation catalog](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/networking#microsoftnetwork)
defines the action names above. The module pins AzureRM 4.81.0; its deployment paths are:

- [Application Gateway](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/network/application_gateway_resource.go):
  GET, PUT and DELETE. A gateway-subnet change additionally calls Stop then Start around
  the PUT, requiring the two explicit actions even though ordinary updates do not.
- [NSG](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/network/network_security_group_resource.go):
  GET, PUT and DELETE of the parent with inline `security_rule` configuration. No separate
  `networkSecurityGroups/securityRules` or `defaultSecurityRules` operations are called.
  [Subnet association](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/network/subnet_network_security_group_association_resource.go)
  reads the subnet/VNet and PUTs the subnet; NSG `join/action` authorizes the linked resource.
- [Public IP](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/network/public_ip_resource.go):
  existing read/write/delete and `join/action` cover its lifecycle and gateway attachment.
  Subnet lifecycle/read/join actions already cover both dedicated subnets. The backend is
  an IP address, so `applicationGateways/backendAddressPools/join/action` for NIC attachment
  is unnecessary. AKS allocates the private frontend through its own cluster identity.
- The [vendored SDK poller](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/vendor/github.com/hashicorp/go-azure-sdk/sdk/client/resourcemanager/poller_lro.go)
  GETs the `Azure-AsyncOperation` or `Location` response URL; the two Network location
  reads cover asynchronous operation status/results, alongside each resource's GET.
- Application A records are owned by ExternalDNS. Terraform only exposes the AppGW
  public IP to the gateway blueprint; no `dnszones/A/write|delete` is needed. Existing
  zone lifecycle and record reads are retained for independent platform DNS resources.

Backend-health POSTs (`applicationGateways/backendhealth/action` and
`getBackendHealthOnDemand/action`), resource health, metrics and effective NSG/route queries
are optional operator diagnostics. AzureRM does not call them for this resource graph;
they remain ungranted. Provisioning completes before Helm backend readiness. An authorized operator
must verify health and cutover readiness as described in the
[AppGW guide](../modules/application-gateway/README.md).

`Microsoft.OperationalInsights/workspaces/sharedKeys/action` is required with
`workspaces/read` to attach the workspace as a diagnostic-settings destination, as
[Microsoft documents in custom role example 3](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access#custom-role-examples).
AzureRM reads the shared keys and stores them in Terraform state. The control-plane workspace sets `local_authentication_enabled = false`, so its keys
cannot authenticate ingestion. It also disables resource-only log access and grants no
workspace query actions or `dataActions` to the provisioner.

`Microsoft.OperationalInsights` and `Microsoft.Insights` must be registered in the
subscription before provisioning. The customer-run setup registers both namespaces on
every run and waits for completion. Registration is safe to repeat; a failed registration
stops setup. The hub's provisioner receives no registration permission;
`resource_provider_registrations = "none"` remains set.

Managed egress also uses explicit `Microsoft.Network/azureFirewalls` and
`firewallPolicies/ruleCollectionGroups` lifecycle actions, policy join permissions,
public-IP write/delete/join and route-table/route write/delete permissions.
Diagnostics require `Microsoft.Insights/diagnosticSettings` read/write/delete and
`Microsoft.OperationalInsights/workspaces` read/write/delete/sharedKeys actions.
The JSON is the authoritative complete action list.

## Why `cluster_bootstrap_perms` must be true

AKS is created with Azure RBAC for Kubernetes and local accounts disabled, so the API
server authorises the provisioner through Azure role assignments on the cluster. Installing
the agent bundle needs cluster-scoped RBAC objects and a Helm release, which
`Azure Kubernetes Service RBAC Reader` (the `cluster_bootstrap_perms = false` branch) cannot
create. The hub always sets the flag; the assignment is made by the module and removed on
destroy.

## IAM-write actions and how to bound them

`roleDefinitions/write` and `roleAssignments/write` at subscription scope let the
provisioner grant itself or anything else any permission, and `agent.tf` in fact creates a
subscription-scoped `actions: ["*"]` role for the agent. Until that role is narrowed, this
custom role is not a security boundary against a compromised hub; it is a boundary against
mistakes and against blast radius outside the actions listed. Levers, cheapest first:

1. **Dedicated subscription per environment.** The role is subscription-scoped; nothing
   outside is reachable.
2. **ABAC condition on the assignment** of this role, restricting
   `roleAssignments/write` to the role definition IDs the module actually assigns (Network
   Contributor `4d97b98b-1d4f-4787-a291-c67834d212e7`, DNS Zone Contributor
   `befefa01-2a29-4197-83a8-272ff33ce314`, Private DNS Zone Contributor
   `b12aa53e-6015-4669-85d0-8515ebb3ae7f`, AKS RBAC Cluster Admin
   `b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b`, AKS RBAC Reader
   `7f6c6a51-bcf8-42ba-9220-52d62157d7db`, plus the environment's agent role). The agent
   role ID is minted by Terraform today, so this needs the module to derive a stable
   `role_definition_id` or the setup to pre-create the agent role — a follow-up.
3. **Pre-created agent role.** Create `ryvn-agent-role-<env>` out of band and have the
   provisioner only assign it, dropping `roleDefinitions/write|delete` entirely. Needs a
   module input; a follow-up together with narrowing the agent role itself.

## Customer-side one-time setup

The orchestrator renders a setup script from this role for a subscription (Azure panel in
the environment wizard, `GET .../environments/provisioning/azure-setup?subscriptionId=`,
or `ryvn get azure-setup-script --subscription <id>`; template in
`internal/provision/azure_setup.go`). It first registers the logging resource providers,
then creates or updates the role, then either a managed identity with a federated
credential (GCP-rooted hub) or a service principal (otherwise), and assigns the role at
subscription scope. Provider registration and role updates are idempotent. Re-running
the client-secret path creates a new password, which must be updated in Ryvn.

Custom role names are unique per Entra tenant, so the script names the role
`ryvn-aks-provision-<first 8 chars of the lowercase subscription ID>`. To do the same by
hand (the CLI needs a top-level `name` in addition to `roleName`):

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv | tr 'A-Z' 'a-z')
ROLE_NAME="ryvn-aks-provision-$(printf %.8s "$SUBSCRIPTION_ID")"
jq --arg n "$ROLE_NAME" --arg s "$SUBSCRIPTION_ID" \
  '. + {name: $n, roleName: $n, assignableScopes: ["/subscriptions/\($s)"]}' \
  provisioner-role.json > /tmp/ryvn-aks-provision.json
az provider register --namespace Microsoft.OperationalInsights --wait -o none
az provider register --namespace Microsoft.Insights --wait -o none
az role definition create --role-definition @/tmp/ryvn-aks-provision.json \
  || az role definition update --role-definition @/tmp/ryvn-aks-provision.json
```

Then either create the service principal (`az ad sp create-for-rbac --name
"ryvn-provisioner-$(printf %.8s "$SUBSCRIPTION_ID")" --role "$ROLE_NAME" --scopes
/subscriptions/${SUBSCRIPTION_ID}`) or, for a GCP-rooted hub, a managed identity with a
federated credential and a role assignment:

```bash
az identity create -g ryvn-provisioner -n ryvn-provisioner -l <location>
az identity federated-credential create -g ryvn-provisioner --identity-name ryvn-provisioner -n ryvn-hub \
  --issuer https://accounts.google.com --subject <hub service account unique id> \
  --audiences api://AzureADTokenExchange
az role assignment create --role "$ROLE_NAME" --scope /subscriptions/${SUBSCRIPTION_ID} \
  --assignee-object-id "$(az identity show -g ryvn-provisioner -n ryvn-provisioner --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal
```

Subscriptions set up before this role granted `actions: ["*"]` under the plain name
`ryvn-aks-provision`. The setup script leaves that role and its assignments untouched:
environments provisioned under it keep using it, new identities get the narrowed role.
Narrow or delete the legacy role only after every environment in the subscription has been
re-applied as described below.

### Upgrading existing subscriptions

Before applying the module with automatic control-plane logging, existing subscriptions
must register both logging providers. Provisioners using the narrowed role also need the
logging actions in the current role definition. Run the commands below as the subscription owner with the
updated `provisioner-role.json`. They update permissions without creating an identity or
rotating its secret:

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv | tr 'A-Z' 'a-z')
ROLE_NAME="ryvn-aks-provision-$(printf %.8s "$SUBSCRIPTION_ID")"
az provider register --namespace Microsoft.OperationalInsights --wait -o none
az provider register --namespace Microsoft.Insights --wait -o none
jq --arg n "$ROLE_NAME" --arg s "$SUBSCRIPTION_ID" \
  '. + {name: $n, roleName: $n, assignableScopes: ["/subscriptions/\($s)"]}' \
  provisioner-role.json > /tmp/ryvn-aks-provision.json
az role definition update --role-definition @/tmp/ryvn-aks-provision.json
```

For identities still assigned to the legacy wildcard role, register both providers and
leave that role unchanged until the cluster migration below is complete. Re-running the
full setup script also applies the logging prerequisites, but its client-secret path
rotates the password and requires updating the saved credentials in Ryvn.

### Enabling managed egress on an existing subscription

The setup script embeds this JSON at orchestrator build time. Ship an orchestrator
release containing the new role before generating updated setup instructions;
merging Terraform alone does not update a running hub or a customer's role.
Update the existing custom role before enabling the firewall. Prefer a role-only
update: rerunning the secret-backed full setup rotates the service-principal
password and requires updating the Ryvn connection. Provider registration remains
customer-owned; ensure Network, Insights and OperationalInsights are registered.
The [egress runbook](../modules/egress-firewall/RUNBOOK.md) covers rollout.

### Enabling Application Gateway on an existing subscription

1. Publish an orchestrator release containing this template, then upgrade the hub serving
   setup instructions. `permissions.go` embeds `provisioner-role.json` at build time;
   merging source does **not** update a running orchestrator or any live customer role.
   The release workflow includes this directory and requires
   `auto-release:ryvn-orchestrator` on the merged PR.
2. Generate the updated setup script through the environment wizard, Azure setup API or
   `ryvn get azure-setup-script` described above. The subscription owner runs the supported
   role-update flow before applying AppGW. Prefer the role-only commands under
   "Upgrading existing subscriptions" with the released JSON: the full client-secret
   setup path rotates the password and requires updating the saved connection.
3. [Update the existing custom role definition](https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles-cli#update-a-custom-role)
   `ryvn-aks-provision-<sub8>` in place, retaining its definition ID. Existing assignments
   to that definition continue to apply; do not recreate identities or assignments just
   to add these actions. The old plain-name wildcard role remains untouched.
4. Allow Azure RBAC propagation, refresh provisioner credentials, and read back the role
   definition and effective assignments for the actual provisioner principal. Confirm
   the new actions and correct subscription scope, including inherited assignments and
   any conditions/deny assignments, before enabling `application_gateway_enabled`.
   Apply the [AppGW rollout gates](../modules/application-gateway/README.md) separately;
   permission readiness does not establish backend, TLS or DNS readiness.

### Restricted-role validation

Prior isolated AppGW tests establish networking and ownership behavior; they do **not**
prove create/update/delete or DNS publication under this restricted role. The action audit,
embedded-role regression and both generated setup-script variants cover source only.

Use an already-authorized disposable provisioner identity and scope with the corrected
definition, or obtain owner authorization separately. Do not update a shared/customer
role, create an assignment or use Owner/Contributor/the agent identity as a substitute.
The remaining scoped validation is:

1. Record the effective principal object ID, subscription, role definition ID/actions,
   assignments (including inherited grants), conditions and deny assignments. Exclude
   broader roles that would mask a missing action. Use the actual supported assignment
   scope in an isolated subscription; Network location polling reads need that coverage.
2. With that identity and isolated Terraform state, create a disposable VNet/subnets,
   public IP, NSG with inline rules, subnet association and AppGW using the actual module,
   before the backend Service exists.
3. Update an inline NSG rule, refresh/reapply, and exercise an approved gateway-subnet
   change to cover AzureRM's Stop/Start branch. Application DNS is reconciled separately
   by ExternalDNS, using its own identity; a provisioner apply must not write A records.
4. Delete only disposable resources with reviewed retirement steps for `prevent_destroy`,
   retain operation/authorization evidence, and verify no leftovers. Neither a no-op
   refresh nor a broad-identity apply establishes these lifecycle permissions. Preserve
   existing validation fixtures; customer-environment validation requires separate authorization.

### Existing clusters: upgrade the module before narrowing the legacy role

A cluster created by an earlier module version still has local accounts enabled. Until an
apply of this version turns them off, the AzureRM provider reads the admin kubeconfig on
every refresh (`listClusterAdminCredential/action`), which this role does not grant, so a
plan, apply or destroy of such a cluster under the narrowed role fails with
`AuthorizationFailed` before it can change anything. Order the migration per environment:

1. Re-apply the environment on this module version under the existing wildcard role. That
   apply sets `disableLocalAccounts` in place; the cluster and workloads are untouched.
2. Only then run `az role definition update` with `provisioner-role.json`.

If the role has already been narrowed, temporarily add
`Microsoft.ContainerService/managedClusters/listClusterAdminCredential/action` to it, run
step 1, and remove the action again. The action is deliberately not part of the shipped
role: it hands out a static cluster-admin credential that bypasses Entra.

# Provisioner permissions

Azure RBAC for the identity that provisions, updates and deprovisions a Ryvn AKS
environment with this module. The counterparts live in
`infra/gke-provision/permissions/` (GCP) and `infra/aws-provision-karpenter/permissions/` (AWS).

| File | Purpose |
|------|---------|
| `provisioner-role.json` | Custom role `ryvn-aks-provision`, replacing the former `actions: ["*"]` definition |
| `permissions.go` | Embeds the role so the orchestrator can serve it (same layout as `infra/gke-provision/permissions`) |

## Identity model

The role is granted at subscription scope to one principal per subscription:

- **Credential-less (GCP-rooted hub).** A user-assigned managed identity with a federated
  identity credential trusting the hub's Google service account: issuer
  `https://accounts.google.com`, subject `<unique ID of the hub service account>`, audience
  `api://AzureADTokenExchange`. Terraform authenticates with `ARM_USE_OIDC=true` and the
  hub's Google ID token as the client assertion; no secret exists on either side and no
  Entra application registration is required.
- **Client secret (AWS-rooted hub, current default).** A service principal created with
  `az ad sp create-for-rbac --role ryvn-aks-provision --scopes /subscriptions/<id>`.

Authorization is identical in both cases: only the way the token is obtained differs, so
the role is not widened for federation.

The runtime identity is different: after bootstrap the in-cluster agent runs as the
`ryvn-agent-<env>` managed identity with the role defined in `agent.tf`. That role is
created *by* the provisioner and is out of scope here (see "IAM-write actions").

## How the role was derived

Live-validated in a scratch subscription with a fresh managed identity holding only this
role (no Owner, Contributor, User Access Administrator, or the old wildcard role), federated
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

## What the provisioner does

| Step | Resources | Actions |
|------|-----------|---------|
| Provider bootstrap | subscription, locations (`Azure/regions` module), provider metadata | `Microsoft.Resources/subscriptions/read`, `subscriptions/locations/read`, `providers/read` |
| Resource group | `ryvn-rg-<env>` | `Microsoft.Resources/subscriptions/resourceGroups/read|write|delete` |
| Network | VNet (or carve in an existing one), node/appgw/privatelink/postgres subnets, route table association, AKS egress IP lookup | `Microsoft.Network/virtualNetworks/*` (read/write/delete), `virtualNetworks/join/action` (private DNS VNet links), `virtualNetworks/subnets/*` (read/write/delete/join), `routeTables/read|join`, `publicIPAddresses/read` |
| DNS | public zone, private zones for internal domain, PostgreSQL and Redis, VNet links | `Microsoft.Network/dnszones/read|write|delete`, `dnszones/*/read` (SOA read-back), `privateDnsZones/read|write|delete`, `privateDnsZones/*/read`, `privateDnsZones/virtualNetworkLinks/read|write|delete` |
| Cluster | AKS with Azure RBAC, workload identity, two node pools | `Microsoft.ContainerService/managedClusters/read|write|delete`, `managedClusters/agentPools/read|write|delete`, `managedClusters/listClusterUserCredential/action` (called by `azurerm_kubernetes_cluster` on every read), `locations/operations/read`, `locations/operationresults/read` (long-running operation polling) |
| Identities | ryvn-agent, external-dns (public and private) and cert-manager identities with federated credentials; kubelet identity assignment | `Microsoft.ManagedIdentity/userAssignedIdentities/read|write|delete|assign/action`, `userAssignedIdentities/federatedIdentityCredentials/read|write|delete` |
| Roles and assignments | agent custom role; Network Contributor / DNS Zone Contributor / Private DNS Zone Contributor / AKS RBAC Cluster Admin assignments | `Microsoft.Authorization/roleDefinitions/read|write|delete`, `roleAssignments/read|write|delete` |
| Agent bootstrap (hub) | Kubernetes objects over the API server | none: authorised by the module's `Azure Kubernetes Service RBAC Cluster Admin` assignment, evaluated by Azure RBAC for Kubernetes; no `dataActions` |
| Teardown | the same set in reverse | the delete actions in each group |

Not needed and deliberately absent: `Microsoft.Resources/deployments/*` (no ARM templates),
resource provider registration (`resource_provider_registrations = "none"`),
`Microsoft.Compute/*`, `Microsoft.Storage/*`, `Microsoft.KeyVault/*`,
`Microsoft.OperationalInsights/*`, `Microsoft.Insights/*`, `Microsoft.Authorization/locks/*`,
`Microsoft.Authorization/policyAssignments/*`, DNS record-set writes.

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

Until the orchestrator serves an Azure setup script, by hand:

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
sed "s#<subscriptionId>#${SUBSCRIPTION_ID}#" provisioner-role.json > /tmp/ryvn-aks-provision.json
az role definition create --role-definition @/tmp/ryvn-aks-provision.json \
  || az role definition update --role-definition @/tmp/ryvn-aks-provision.json
```

Then either create the service principal (`az ad sp create-for-rbac --name ryvn-provisioner
--role ryvn-aks-provision --scopes /subscriptions/${SUBSCRIPTION_ID}`) or, for a GCP-rooted
hub, a managed identity with a federated credential and a role assignment:

```bash
az identity create -g <rg> -n ryvn-provisioner -l <location>
az identity federated-credential create -g <rg> --identity-name ryvn-provisioner -n ryvn-hub \
  --issuer https://accounts.google.com --subject <hub service account unique id> \
  --audiences api://AzureADTokenExchange
az role assignment create --role ryvn-aks-provision --scope /subscriptions/${SUBSCRIPTION_ID} \
  --assignee-object-id "$(az identity show -g <rg> -n ryvn-provisioner --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal
```

Subscriptions set up before this role granted `actions: ["*"]` under the same role name;
`az role definition update` replaces the definition in place, so existing assignments pick
up the narrower actions without being recreated.

### Existing clusters: upgrade the module before narrowing the role

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

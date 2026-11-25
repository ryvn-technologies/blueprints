# Azure AKS Platform Module

Provisions the Azure half of a Ryvn environment: a resource group, a VNet (or a
carve inside one you already have), an AKS cluster with Workload Identity, DNS
zones for the environment's public and internal names, and the managed
identities the in-cluster components federate with.

This module is not meant to be consumed directly: it backs the `azure-platform`
blueprint, and Ryvn applies it once per environment with inputs taken from the
environment's configuration. It is published for review — so you can see exactly
what gets created in your subscription before you hand one over. To create an
environment, see the [Azure environment
docs](https://ryvn.ai/docs/iac/environments/azure); the variables below are the
knobs those docs expose.

Setting `existing_route_table_id` switches the cluster's outbound type to
`userDefinedRouting`: AKS provisions no load-balancer egress IP, and the route
table's UDRs decide where traffic goes. `outbound_ips` is then empty, because the
public source address is whatever the network appliance NATs to.

For root-owned VNets, `egress_firewall.enabled = true` instead creates an Azure
Firewall with default-deny external IPv4 egress and source-scoped AKS and
external policy classes. The cluster uses UDR outbound; its platform HTTPS/443
hosts are supplied separately from customer rules. `additional_subnet_groups`
allocates ordered, append-only external subnets independently of the firewall;
`egress_attachments` maps a group to a named policy. Unattached groups have
`0.0.0.0/0 -> None` and Azure default outbound access disabled. See the
[egress firewall reference](modules/egress-firewall/README.md) and
[operator runbook](modules/egress-firewall/RUNBOOK.md) for inputs, limits, migration
and teardown.

Public TCP ingress can opt into the platform-owned [Application Gateway module](modules/application-gateway/README.md).
Set `application_gateway_enabled: true` to provision AppGW and its dedicated frontend
subnet/IP. The enabled external gateway automatically consumes platform output. For managed
egress, explicitly enable the independent `egress_firewall.enabled` setting too.
Helm/ryvn-agent deploys the separate private external-Istio Service, and AKS reconciles its frontend.
ExternalDNS owns application DNS: the existing external Service publishes the AppGW
public IP, and i2gw publishes it through Ingress status when enabled. Explicit Ingress
targets remain operator-owned and need manual review. Applied Terraform DNS requires the
reviewed non-destructive ownership handoff in the runbook before resource removal.
Use an owner-approved, deployment-specific activation and rollback procedure; private operational evidence is not published with this module.

## What's Included

- **Network**: a VNet (or a carve inside an existing one) with regional node-pool
  subnets plus subnets for Application Gateway and private endpoints,
  service endpoints in the default networking mode, and route-table
  associations. Managed firewall mode removes node-subnet service endpoints.
  `NETWORKING_EXAMPLES.md` works through the address math for
  `/16`, `/20` and `/23` ranges in both CNI modes.
- **Cluster**: AKS Standard with Azure CNI (overlay by default), Azure network
  policy, Azure Policy, OIDC issuer and Workload Identity, Entra-integrated
  Azure RBAC, cost analysis, and the Key Vault Secrets Store CSI provider.
  Autoscaling is on for every pool. Kubernetes Secrets are encrypted with
  [AKS KMS data encryption](https://learn.microsoft.com/en-us/azure/aks/kms-data-encryption)
  using a platform-managed key that AKS rotates; enabling it on an existing
  cluster re-encrypts the Secrets already stored.
- **Node pools**: a `CriticalAddonsOnly`-tainted system pool and an
  `application` pool, spread across the region's availability zones. Pass
  `aks_node_pools` to override sizes or add pools; values merge with the
  defaults per key.
- **Identity**: user-assigned managed identities for the Ryvn agent (with a
  custom subscription-scoped role), external-dns (public and private zones
  separately) and cert-manager, each federated to its in-cluster service
  account.
- **Control-plane logs**: a Log Analytics workspace and an AKS diagnostic setting
  collect `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`,
  `cluster-autoscaler`, `guard`, and full `kube-audit` logs automatically.
  Logs use the resource-specific `AKSControlPlane` and `AKSAudit` tables.
- **DNS**: a public DNS zone, a private zone for the internal domain, and
  private zones for PostgreSQL Flexible Server and Redis so the managed
  data-service blueprints can attach private endpoints. All private zones are
  linked to the VNet.

## Key Variables

| Name | Description | Default |
|------|-------------|---------|
| `environment_name` | Environment name, used as a suffix throughout | required |
| `location` | Azure region | required |
| `public_root_domain` / `internal_root_domain` | Domains for the DNS zones | required |
| `cluster_version` | Kubernetes minor version for the control plane and every node pool; see [Kubernetes version upgrades](#kubernetes-version-upgrades) | `"1.34"` |
| `node_os_channel_upgrade` | Node OS image upgrade channel (`None`, `Unmanaged`, `SecurityPatch`, `NodeImage`) | `"NodeImage"` |
| `maintenance_window_node_os` | Planned maintenance schedule for node OS image upgrades; `null` lets Azure upgrade at any time | Sundays 00:00-08:00 UTC |
| `maintenance_window_auto_upgrade` | Planned maintenance schedule for Kubernetes patch auto-upgrades; `null` lets Azure upgrade at any time | Sundays 00:00-08:00 UTC |
| `vnet_cidr` | VNet address space, or the range reserved for Ryvn inside an existing VNet | `"10.0.0.0/16"` |
| `network_plugin_mode` | `overlay` or `flat`; changing it replaces the cluster | `"overlay"` |
| `pod_cidr` | Pod range in overlay mode | `"192.168.0.0/16"` |
| `existing_vnet_id` | Carve subnets inside an existing VNet | `null` |
| `existing_route_table_id` | Associate node subnets with an existing route table and use UDR egress | `null` |
| `aks_node_pools` | Node pool overrides, merged with the defaults | `{}` |
| `zones` | Availability zones for the node pools | `null` (all zones in the region) |
| `control_plane_log_retention_days` | Retention for control-plane and full audit logs, in whole days from 30 to 730 | `30` |
| `cost_analysis_enabled` | AKS cost analysis add-on | `true` |
| `key_vault_secrets_provider_enabled` | Key Vault Secrets Store CSI add-on | `true` |
| `cluster_bootstrap_perms` | Grant the Terraform identity cluster admin for bootstrap | `false` |
| `terraform_executor_policies` | Replace the agent's default grants with Azure custom permissions and/or scoped existing roles | `{}` |
| `tags` | Extra tags, merged with the module's own | `{}` |
| `egress_firewall` | Managed default-deny policy, named HTTP/HTTPS and IPv4 network rules, Standard/Premium tier | disabled |
| `platform_https_domains` | Exact additional HTTPS/443 platform hosts for cluster sources | `[]` |
| `additional_subnet_groups` | Ordered subnet allocation ledger (name, IPv4 prefix, retired flag) | `[]` |
| `egress_attachments` | Named policy assignments to active allocated subnet groups | `{}` |

### Agent executor permissions

By default, the agent's managed identity receives a custom role with `actions = ["*"]`
at subscription scope and no explicit data actions. Set `terraform_executor_policies`
in the environment's configuration to replace that entire grant. You can use the
frontend's advanced YAML editor, environment YAML through the CLI/GitSync, or the API.
The Azure module release installed in the environment must include this input.

The object accepts two fields, which can be used separately or together:

- `permissions`: creates the environment's custom role from `actions`, `not_actions`,
  `data_actions`, and `not_data_actions`. Each list defaults to empty; at least one
  action or data action is required. Optional `scope` sets the assignment scope,
  defaulting to the deployment subscription. It must be that subscription or a resource
  group/resource within it. The role definition stays at subscription scope.
- `role_assignments`: a map keyed by stable assignment names. Each entry selects
  exactly one built-in `role_definition_name` or full Azure `role_definition_id`.
  Optional `scope` defaults to the deployment subscription and must stay within it.
  Use an unescaped ARM scope ID without URL escapes, query strings, fragments, or dot
  segments. Use the ARM resource ID
  for an existing custom role, not a bare GUID or Terraform's composite state ID.

Both `permissions` and each role assignment accept an optional Azure ABAC `condition`.
The module sets `condition_version = "2.0"` when a condition is supplied. Azure supports
conditions only for specific actions and attributes; these are not generic filters for
all management operations. See [Azure role assignment conditions](https://learn.microsoft.com/en-us/azure/role-based-access-control/conditions-overview).

For example, this environment config fragment uses built-in roles at resource-group
and storage-container scope:

```yaml
terraform_executor_policies:
  role_assignments:
    network:
      role_definition_name: Network Contributor
      scope: /subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/example-network
    artifacts:
      role_definition_name: Storage Blob Data Reader
      scope: /subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/example-data/providers/Microsoft.Storage/storageAccounts/examplestorage/blobServices/default/containers/artifacts
```

For a custom role, supply the native permission lists instead:

```yaml
terraform_executor_policies:
  permissions:
    scope: /subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/example-data
    actions:
      - Microsoft.Storage/storageAccounts/read
    data_actions:
      - Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read
```

These examples illustrate the input shape; they are not complete permission sets for
every blueprint. Include every operation your installations need, including identity
or role management only when required. No permissions are added to your override.
With `role_assignments` alone, the module removes its custom role and default assignment.
Empty, omitted, or null `terraform_executor_policies` restores the broad default;
`permissions: {}` is rejected instead of silently granting wildcard access.

`not_actions` and `not_data_actions` subtract permissions from this custom role; they
are not deny rules. Other assignments, including inherited or externally managed grants,
can still allow those actions. See [Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions).

This configures the runtime agent, not the separate identity that provisions the platform.
Every assignment scope is limited to the deployment subscription or its descendants,
even if the provisioner has broader Azure authority. The provisioner needs permission to
read the selected role definition. Cross-subscription or management-group grants must be
managed separately by an administrator of the target scope. Switching to pre-created roles
does not automatically narrow that provisioner role; see [Provisioner permissions](permissions/README.md#iam-write-actions-and-how-to-bound-them).

Review the Terraform plan before applying an override. State moves preserve existing role
and assignment identities for unchanged defaults. An assignments-only override removes
the old role; changing assignment scope, role, or condition can replace assignments.
Role changes and Azure RBAC propagation can interrupt in-flight deployments. Reverting to
empty configuration restores the subscription-wide wildcard grant.

### Kubernetes version upgrades

`cluster_version` sets the control plane and every node pool, including
`system`, `application` and custom pools. Raising it upgrades the control
plane, then rolls each pool in place: AKS adds surge nodes, cordons and drains
old nodes, and replaces them with nodes on the new version. Every node in every
pool is replaced. Pools can roll at the same time. Drains respect
PodDisruptionBudgets, so a budget that allows no evictions blocks a pool until
it is cleared or the drain timeout passes. Each pool update waits up to 30
minutes; if Terraform times out first, re-apply after AKS finishes the
operation. The first apply on an existing cluster sets each pool to
`cluster_version`, which can replace nodes once.
If the cluster was upgraded outside Terraform, set `cluster_version` to the
live minor before applying.

Run `bash infra/azure-aks-provision/tests/check_cluster_version_upgrade.sh`
from the repository root after `terraform init -backend=false` in this module.
It applies the default version with mock providers, then checks that the same
version plans no change and the next minor updates every pool without
replacing the cluster or a node pool.

AKS upgrades one minor version at a time, so raise `cluster_version` by one
minor per apply. Upgrades cannot be undone: AKS does not downgrade the control
plane or node pools. `automatic_channel_upgrade = "patch"` keeps patch versions
current within the minor in maintenance windows. A minor upgrade can also move
nodes to a newer default OS image, which the Terraform plan does not show; for
example, 1.34 to 1.35 moves Ubuntu nodes from 22.04 to 24.04.

### Node counts

Every pool autoscales between `min_count` and `max_count`. Terraform does not
manage the live node count: the cluster autoscaler owns it, and Azure creates a
new pool at `min_count`. `aks_node_pools.<name>.node_count` is accepted but has
no effect.

### Additional-pool upgrade settings

The `system` pool upgrades with 33% surge. `aks_node_pools.<name>.upgrade_settings`
is an optional pass-through to pinned Azure/aks 11.7.0 for regular additional
pools, including `application`. Omitted or `null` gives `application` 33%
surge, 30-minute drain and no soak, and gives every custom pool 33% surge only.
The embedded `system` pool uses separate upstream inputs: `system.upgrade_settings`
accepts only `undrainable_node_behavior`, which must be `Cordon` or `Schedule`,
and keeps 33% surge. Its other fields must be omitted or `null`. Flat-network
pools near subnet capacity should set an explicit `max_surge` or `max_unavailable`.

An explicit block replaces the entire pool default. Set exactly one nonempty
`max_surge` or `max_unavailable` string and leave the other omitted or `null`.
No default surge is merged into an unavailable strategy. Optional
`drain_timeout_in_minutes`, `node_soak_duration_in_minutes` (numbers) and
`undrainable_node_behavior` (string) pass through unchanged. Omitted fields in an
explicit block pass through as `null`; provider/Azure defaults apply rather than
inheriting the `application` 30-minute drain and no soak. AzureRM replaces a pool
when `drain_timeout_in_minutes` changes from set to unset, so a surge-only
override of `application` replaces that pool; overrides of `application` should
keep `drain_timeout_in_minutes`.

Once `undrainable_node_behavior` is set on any pool, do not remove it. AzureRM
replaces the cluster when it is removed from the `system` pool and replaces the
pool when it is removed from another pool. Switching between `Cordon` and
`Schedule` is an in-place update. If it was set on a pool outside Terraform,
declare the live value before applying. Rolling back to a module version without
the `system` input unsets it and replaces the cluster.

```hcl
aks_node_pools = {
  sandbox = {
    vm_size          = "Standard_D4als_v7"
    min_count        = 0
    max_count        = 2
    upgrade_settings = { max_surge = "10%" }
  }
}
```

Run `bash infra/azure-aks-provision/tests/check_node_pool_upgrade_settings.sh`
from the repository root after `terraform init -backend=false` in this module.
It checks the actual upstream node-pool resource plans and input validation with
mock providers.

## Outputs

`cluster` (name, endpoint, CA data, OIDC issuer and node resource group),
`vnet`, `resource_group`, `subscription`, `public_domain`, `internal_domain`,
`outbound_ips`, and the client IDs of the Ryvn agent, external-dns and
cert-manager identities. `additional_subnet_groups` lists active allocated
subnets even with the firewall disabled; `egress_firewall` reports enabled
status, protected attachments, native Azure references and effective rules.

## Control-plane logging

The workspace is in the environment's resource group, uses Entra
workspace permissions for access, and retains logs for 30 days by default.
Full `kube-audit` includes read events and incurs Log Analytics ingestion and
retention charges. Azure's managed audit policy still determines which requests
and details are recorded.

The workspace belongs to the environment lifecycle. A long-term archive must
be managed separately if its logs need to outlive environment deletion.
Container Insights, workload collection, and metrics are unchanged. Before
upgrading an existing environment, update its provisioner role and register the
logging providers as described in [Provisioner permissions](permissions/README.md).

## Provisioner Permissions

The identity that applies this module needs the custom role in
`permissions/provisioner-role.json` at subscription scope, and nothing broader.
`permissions/README.md` explains how the role was derived and what each group
of actions is for. Kubernetes local accounts are disabled on the cluster, so the
module exports no kubeconfig or client certificate; every client, including the
provisioner during agent bootstrap, authenticates to the API server with an
Entra token evaluated by Azure RBAC for Kubernetes.

## One-Way Decisions

`network_plugin_mode`, the VNet address space and the subnet layout are fixed
after creation — switching CNI modes or resizing the carve means replacing the
cluster. Because the node resource group name is derived from the environment
name, renaming an environment is also a replacement. Secrets encryption needs
Kubernetes 1.33 or later and can't be turned off once enabled. Applied `additional_subnet_groups`
entries cannot be renamed, reordered or resized; retirement reserves their space.
Their allocation records deliberately block ordinary environment destruction until
explicitly released; see the [egress runbook](modules/egress-firewall/RUNBOOK.md).

The module is synced to `ryvn-technologies/blueprints` under `azure/aks` on
every merge to `main`.

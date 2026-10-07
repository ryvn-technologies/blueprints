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
See the Ryvn monorepo's [activation and rollback runbook](https://github.com/ryvn-technologies/ryvn/blob/main/docs-internal/runbooks/azure-application-gateway-ingress.md); internal docs are not copied into the published blueprints repository.

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
  Autoscaling is on for every pool.
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
| `cluster_version` | AKS Kubernetes version | `"1.34"` |
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
| `tags` | Extra tags, merged with the module's own | `{}` |
| `egress_firewall` | Managed default-deny policy, named HTTP/HTTPS and IPv4 network rules, Standard/Premium tier | disabled |
| `platform_https_domains` | Exact additional HTTPS/443 platform hosts for cluster sources | `[]` |
| `additional_subnet_groups` | Ordered subnet allocation ledger (name, IPv4 prefix, retired flag) | `[]` |
| `egress_attachments` | Named policy assignments to active allocated subnet groups | `{}` |

### Additional-pool upgrade settings

`aks_node_pools.<name>.upgrade_settings` is an optional pass-through to pinned
Azure/aks 11.7.0 for regular additional pools, including `application`. Omitted
or `null` preserves existing behavior: `application` keeps 10% surge, 30-minute
drain and 5-minute soak; custom pools have no configured upgrade-settings block.
The embedded `system` pool uses separate upstream surge-only inputs; providing
`system.upgrade_settings` is rejected.

An explicit block replaces the entire pool default. Set exactly one nonempty
`max_surge` or `max_unavailable` string and leave the other omitted or `null`.
No default surge is merged into an unavailable strategy. Optional
`drain_timeout_in_minutes`, `node_soak_duration_in_minutes` (numbers) and
`undrainable_node_behavior` (string) pass through unchanged. Omitted fields in an
explicit block pass through as `null`; provider/Azure defaults apply rather than
inheriting the application's 30-minute drain and 5-minute soak. This also applies
when overriding `application`.

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
name, renaming an environment is also a replacement. Applied `additional_subnet_groups`
entries cannot be renamed, reordered or resized; retirement reserves their space.
Their allocation records deliberately block ordinary environment destruction until
explicitly released; see the [egress runbook](modules/egress-firewall/RUNBOOK.md).

The module is synced to `ryvn-technologies/blueprints` under `azure/aks` on
every merge to `main`.

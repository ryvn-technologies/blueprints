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

## What's Included

- **Network**: a VNet (or a carve inside an existing one) with per-AZ private
  node subnets plus subnets for Application Gateway and private endpoints,
  service endpoints for the managed data services, and route table
  associations. `NETWORKING_EXAMPLES.md` works through the address math for
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
| `vnet_cidr` | VNet address space, or the range reserved for Ryvn inside an existing VNet | `"10.0.0.0/16"` |
| `network_plugin_mode` | `overlay` or `flat`; changing it replaces the cluster | `"overlay"` |
| `pod_cidr` | Pod range in overlay mode | `"192.168.0.0/16"` |
| `existing_vnet_id` | Carve subnets inside an existing VNet | `null` |
| `existing_route_table_id` | Associate node subnets with an existing route table and use UDR egress | `null` |
| `aks_node_pools` | Node pool overrides, merged with the defaults | `{}` |
| `zones` | Availability zones for the node pools | `null` (all zones in the region) |
| `cost_analysis_enabled` | AKS cost analysis add-on | `true` |
| `key_vault_secrets_provider_enabled` | Key Vault Secrets Store CSI add-on | `true` |
| `cluster_bootstrap_perms` | Grant the Terraform identity cluster admin for bootstrap | `false` |
| `tags` | Extra tags, merged with the module's own | `{}` |

## Outputs

`cluster` (name, endpoint, CA data, OIDC issuer and node resource group),
`vnet`, `resource_group`, `subscription`, `public_domain`, `internal_domain`,
`outbound_ips`, and the client IDs of the Ryvn agent, external-dns and
cert-manager identities.

## One-Way Decisions

`network_plugin_mode`, the VNet address space and the subnet layout are fixed
after creation — switching CNI modes or resizing the carve means replacing the
cluster. Because the node resource group name is derived from the environment
name, renaming an environment is also a replacement.

# Azure managed egress firewall

Feature reference for the `azure-aks-provision` root module. Configure the root
inputs below; this child is an internal compiler/resource boundary and relies on
root validation and routing. For customer setup and recovery, use the
[operator runbook](RUNBOOK.md). Historical test evidence is in the Ryvn monorepo's
[Azure validation report](https://github.com/ryvn-technologies/ryvn/blob/main/docs-internal/changes/cloud-egress-firewall/azure-validation.md).

## Architecture and ownership

```text
AKS pods -> node-pool subnet UDR -------> Azure Firewall -> public API
attached VM -> group subnet UDR ------->       |
                                              +-> native verdict/DNS logs
unattached group -> default drop route

stable Standard base policy: post-cluster AKS API exception
  -> tier-specific child policy: cluster baseline + source-scoped customer rules
```

The root owns the VNet, fixed `AzureFirewallSubnet`, subnet allocations, route
associations and post-cluster API rule. This child owns the firewall, one Standard
static public IP, base/child policies, cluster route table and Log Analytics.
Every AKS node-pool subnet shares the cluster permission class. Overlay pod egress
is SNATed to node addresses; flat mode uses the node/pod subnet ranges. Cloud
firewall logs identify network sources, not namespaces or individual overlay pods.

Managed mode uses AKS `userDefinedRouting`, removes node-subnet service endpoints
that bypass the firewall, and exports the firewall SNAT address through
`outbound_ips`. It requires a root-owned VNet of `/21` or larger; it rejects
`existing_vnet_id` and `existing_route_table_id`. Disabled mode keeps the existing
AKS outbound behavior. This does not privatize the AKS API.

## Root configuration

```hcl
egress_firewall = {
  enabled            = true
  tier               = "Standard"
  cluster_policy_key = "cluster"
  policies = {
    cluster = {
      domain_allow = {
        vendor_api = { domains = ["api.vendor.example"], protocol = "https" }
      }
    }
    external = {
      domain_allow = {
        partner = { domains = ["*.partner.example"], protocol = "https" }
      }
    }
  }
}

# Optional exact cluster-only hosts; the Ryvn blueprint derives managing-hub hosts.
platform_https_domains = ["hub.customer.example"]

# Optional compute outside AKS: allocation is independent of firewall membership.
additional_subnet_groups = [{ name = "api_clients", ipv4_prefix_length = 24 }]
egress_attachments = {
  api_clients = { subnet_group_key = "api_clients", policy_key = "external" }
}
```

Omitted `default_action` is `"deny"`; no permit-rest mode exists. Omitted
`log_retention_days` is 30. `policies[cluster_policy_key]` must exist even if empty.
`domain_allow` and `network_allow` are named maps; omitted maps are empty.

| Rule/input | Behavior |
| --- | --- |
| `domain_allow.<name>` | Nonempty lowercase exact or leading `*.` names, `protocol = "http"` or `"https"`. Optional `destination_ports` must be exactly `[80]` or `[443]` respectively. |
| Wildcard | `*.example.com` matches descendants, not the apex or `notexample.com`. Add the apex separately. Public-suffix-wide patterns are rejected. |
| `network_allow.<name>` | Explicit `destination_ipv4_cidrs`, `protocol = "tcp"` or `"udp"`, integer `destination_ports`, and nonempty `reason`. Use reviewed public CIDRs; private/platform ranges and UDP/443 are rejected. |
| `platform_https_domains` | Bare exact lowercase hostnames, HTTPS/443 only, cluster sources only. No URL, port or wildcard. |

HTTP rules inspect Host; HTTPS rules inspect visible SNI without decrypting TLS.
They do not restrict URL paths, API accounts or encrypted payloads. ECH is not
validated. Azure evaluates network rules before application rules: an allowed
IP/port bypasses hostname checks. A final HTTP/80 + HTTPS/443 application deny
and native unmatched-traffic denial close the remaining inspected paths.
See [Azure rule processing](https://learn.microsoft.com/en-us/azure/firewall/rule-processing).

## Platform defaults and policy scope

The built-in AKS/registry baseline and `platform_https_domains` apply only to
cluster sources. External attachments receive customer rules only, even if they
select the same `policy_key` as the cluster. All application pods can use their
node class's baseline; Kubernetes/Cilium policy supplies finer isolation.

The Azure blueprint derives managing-hub API, issuer, tunnel, effective collector
and observability hosts before infrastructure creation. Non-HTTPS/non-443 endpoints
fail validation when managed egress is enabled. Direct Terraform consumers supply
their platform hosts themselves. Verify collector endpoint overrides when a hub
has no observability endpoints; chart defaults are not discovered by Terraform.

Baseline `azure-aks-v2` includes AKS, Docker Hub authentication and blob delivery,
Ryvn registries, GHCR, Kubernetes (including `cdn.registry.k8s.io`), Istio and Quay,
and production ACME. Azure Policy/Key Vault rules follow their feature conditions.
Shared add-on hosts remain allowed even if that add-on is not installed. The
reviewed `*.pkg.dev` and `*.quay.io` exceptions permit shared registry infrastructure;
`*.pkg.dev` is not confined to the Istio project. Narrower mirrors/host inventories
are follow-up work (ENG-2428). No unconditional public NTP exception is added.

Inspect `egress_firewall.effective_rules`, `compiled_policy`,
`platform_baseline_version`, `configured_scope` and `exclusions` in the plan/output.
The post-cluster API TCP/443 rule deliberately bypasses hostname inspection for
cluster sources, using the API FQDN resolved by the firewall DNS proxy. VNet DNS
and private-zone links are preserved; clients are not switched to proxy DNS.

## Subnet allocation and consumers

Each additional group creates **one regional subnet**, not one per AZ. It does
not create an AKS node pool. Groups allocate sequentially inside
`cidrsubnet(vnet_cidr, 3, 3)`; names, positions, sizes and CIDRs become permanent
allocation records. Add capacity by appending a group. Geometry postconditions
and `prevent_destroy` reject edits, reorders, renames and removal after apply.

`egress_attachments` creates no subnets. One active group can select one policy;
multiple groups can share that policy. Changing an attachment key/policy does not
rename the subnet. A detached active group keeps its subnet and an explicit
`0.0.0.0/0 -> None` route, with Azure default outbound disabled. Private VNet
routes remain reachable. Retiring a group removes its subnet after consumers are
removed, but its allocation tombstone reserves the address space permanently.
Retirement does not reclaim capacity or permit deleting the list entry.

Use `additional_subnet_groups` for active network inventory. A compute consumer
uses the protected descriptor:

```hcl
# Inside a customer-owned NIC resource; other required fields omitted.
ip_configuration {
  name                          = "private"
  subnet_id                     = module.platform.egress_firewall.attachments["api_clients"].subnet_id
  private_ip_address_allocation = "Dynamic"
}
```

The descriptor includes `schema_version = 1`, `provider = "azure"`, policy/group
keys, resource group, location, VNet/subnet IDs, CIDR and route-table ID. Consumers
own compute and NIC security groups; they must not overwrite producer routes or
associations. In separate states, export the descriptor after a successful producer
apply, then apply consumers. JSON IDs carry no Terraform ordering or health guarantee.

## Lifecycle, limits and operational ownership

- **Fresh create:** one ordinary apply with `enabled = true`; network and firewall
  precede AKS, then the stable base policy receives the discovered API exception.
  Wait for the full producer apply before in-cluster bootstrap. No allow-all phase.
- **Existing environment:** enabling/disabling changes routing, service endpoints
  and outbound public IPs. Review resource replacements and downstream IP/service
  ACLs; use a maintenance window. Existing VM NICs can retain implicit outbound
  until a supported node replacement/maintenance step; verify that fallback is
  removed ([Azure behavior](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access)).
  Convergence is not an atomic traffic cutover.
- **Ingress:** the default egress route can make public LoadBalancer return traffic
  asymmetric. This module does not configure firewall DNAT or ingress routing.
  Design and test internal-LB/private ingress or a reviewed firewall DNAT path
  before customer activation; an egress allowlist does not solve ingress.
- **Tier:** Standard is the default. Selecting Premium does not enable TLS
  inspection or IDPS. Tier changes replace the child policy while retaining the
  base/API exception; capacity and migration failures can interrupt service.
  Prior upgrade succeeded; downgrade and zero-downtime migration are not validated.
- **Scope:** public IPv4 egress from protected subnets. VNet/private endpoint paths,
  IMDS/Azure platform VIPs and managed services' own egress are excluded. Putting
  a database private endpoint in this VNet does not inspect that service's egress.
- **Capacity/cost:** one firewall public IP is implemented, with no multi-IP or NAT
  Gateway capacity input. Microsoft recommends sizing SNAT for production AKS
  (its current guidance starts at 20 frontend IPs). The pilot tests are not a
  production connection-capacity benchmark. Budget for firewall, public IP and
  Log Analytics charges; choose region/zones and retention deliberately.
- **Drift:** restrict route/firewall mutation to provisioning and break-glass
  identities. Alert on changes; review Terraform drift and repeat allow/deny
  canaries after repair. The module cannot protect against privileged alternate
  routes, NICs, NAT or firewall changes.
- **Deletion:** allocation records intentionally block a normal destroy when
  groups exist. The [runbook](RUNBOOK.md#retirement-and-full-deletion) describes
  consumer ordering and explicit state release. Disabling also removes the
  firewall logging workspace; archive required evidence first.

Native application/network/DNS logs go to a module-created workspace in the
customer subscription. `egress_firewall.log_refs` provides resource IDs and KQL
queries. A timeout alone is not proof of a firewall deny. Verify a known log canary
and correlate source, destination, rule and time. Route-level drops on detached
subnets produce no firewall verdict.

Provider references: [AKS firewall/ingress and SNAT guidance](https://learn.microsoft.com/en-us/azure/aks/limit-egress-traffic),
[SKU changes](https://learn.microsoft.com/en-us/azure/firewall/change-sku).

## Maintaining domain validation

The ASCII-normalized Public Suffix List is vendored alongside this module, with
upstream license/version metadata. From this directory, refresh it with
`python3 update_public_suffix_list.py` and verify it with
`python3 update_public_suffix_list.py --check`; review AWS/Azure parity when
updating. Terraform never fetches the list during plan/apply. Azure-specific
hosted-service exclusions remain stricter than the PSL.

## Validation boundary

Direct-cloud Round 7 validated Standard in West US 2 with Azure CNI overlay and
Azure dataplane: enabled-first bootstrap, ordinary/hostNetwork pod and VM traffic,
57/57 native verdict matches, registry/blob pulls, source isolation, attachment
changes, append/detach/restore and final no-op plans. A subnet/policy race was fixed
by ordering subnet writes before firewall operations and associations afterward.
This ordering does not serialize external writers.

Ryvn new/existing-environment E2E is a post-merge gate before customer activation:
Cilium, agent reconnect/Connect, certificate issuance, full add-on rollout, public
or private ingress as selected, and populated-state migration remain to be tested.
Flat networking has deterministic topology coverage; the latest live round used
overlay. Direct `registry.istio.io` pull was incomplete (auth HTTP 404); the
GAR-backed Istio image pull passed. No promise of production readiness or atomic
migration follows from merge alone.

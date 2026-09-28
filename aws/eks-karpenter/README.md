# AWS EKS Platform Module

Provisions the AWS half of a Ryvn environment: a VPC (or a carve inside one you
already have), an EKS cluster with Karpenter for node autoscaling, Route 53
zones for the environment's public and internal domains, and the IAM roles the
in-cluster components assume.

This module is not meant to be consumed directly: it backs the `aws-platform`
blueprint, and Ryvn applies it once per environment with inputs taken from the
environment's configuration. It is published for review — so you can see exactly
what gets created in your account before you hand one over. To create an
environment, see the [AWS environment
docs](https://ryvn.ai/docs/iac/environments/aws); the variables below are the
knobs those docs expose.

## What's Included

- **Network**: three-AZ VPC with public, private and intra subnets, single NAT
  gateway, an S3 gateway endpoint on the private route table, optional flow
  logs and optional transit gateway landing-pad subnets.
- **Cluster**: EKS with a private endpoint plus a public endpoint restricted to
  the Ryvn control plane and any CIDRs you allow, control-plane logging, IRSA
  and Pod Identity, and envelope encryption with a customer-managed KMS key by
  default.
- **Node groups**: a small `CriticalAddonsOnly` system group for the components
  Karpenter itself depends on; all other capacity comes from Karpenter.
- **Add-ons**: VPC CNI, CoreDNS, kube-proxy, EBS CSI, EFS CSI, Pod Identity
  agent, and Karpenter's controller IAM role and interruption queue.
- **IAM**: roles for the Ryvn agent, external-dns, cert-manager, the AWS Load
  Balancer Controller, cluster-autoscaler (opt-in) and the Cilium operator
  (when `cni = "cilium"`). Every role can carry a permissions boundary.
- **DNS**: a public and a private Route 53 zone, with a CAA record on the
  public zone.

## Networking Modes

| Mode | Selected by | Module creates |
|------|-------------|----------------|
| Ryvn-provisioned VPC | neither `existing_vpc_id` nor subnet IDs | VPC, subnets, route tables, NAT |
| BYO VPC, carve | `existing_vpc_id` | subnets and route tables inside your VPC; NAT only when `egress_mode = "create_nat"` |
| BYO VPC, subnets | `existing_vpc_id` + `existing_workload_subnet_ids` | no network topology at all |

`network.tf` holds every conditional for these modes and normalizes them onto
one set of locals, so the rest of the module never learns which mode is active.
Its preconditions fail the plan (rather than a partial apply) when a carve would
overlap existing subnets, fall outside the VPC's CIDR associations, miss an AZ
covered by the transit gateway attachment, or land in subnets without a default
route.

### S3 gateway endpoint

S3 traffic from the nodes, including every ECR image layer, otherwise leaves
through the NAT gateway and pays its per-gigabyte fee. A gateway endpoint on the
private route table sends it over the AWS backbone instead, at no charge.
`vpc_endpoints.tf` creates one by default in a Ryvn-provisioned VPC, and never
in a BYO VPC: that network's design and egress path belong to the customer, who
adds the endpoint themselves from the account that owns it. Set
`create_s3_gateway_endpoint = false` to opt a Ryvn-provisioned VPC out; setting
it `true` alongside `existing_vpc_id` fails the plan.

Once the endpoint exists, S3 sees requests from this environment arriving from
the VPC rather than from `outbound_ips`. Bucket policies elsewhere that allow
the environment by NAT address must switch to an `aws:SourceVpc` condition.

### Managed egress firewall (`egress_firewall.enabled = true`)

Enabled mode requires `cni = "cilium"` and rebuilds egress for a
Ryvn-provisioned VPC as `private subnet -> AZ-local Network Firewall endpoint
-> AZ-local NAT -> IGW`, default-deny on public IPv4 with hostname (SNI/Host)
and narrow IP/port exceptions. `egress_network/` is the child module; the
contract lives in `docs-internal/changes/cloud-egress-firewall/`. Disabled mode
(the default) keeps the legacy network behaviour: single NAT, one private
route table, S3 gateway endpoint included. It is not byte-for-byte the
previous module (the VPC module moved from 5.14 to 5.21 alongside this work;
review the plan for provider-driven diffs), and the enable/disable flip itself
replaces the NAT gateways, route ownership and public egress IPs, so it is a
migration, not a toggle. Enabled mode drops the S3 gateway endpoint so image
layers take the inspected NAT path. That path is billed as Network Firewall
data processing plus NAT, but AWS's [Network Firewall
pricing](https://aws.amazon.com/network-firewall/pricing/) waives the standard
NAT gateway hourly and per-GB processing charges for traffic that also passes
a firewall endpoint on the same path (check the current conditions for your
region), so do not assume the two fees simply add. A restricted S3 gateway endpoint (endpoint
policy allow-listing verified platform and customer buckets, attached to every
protected route table) is a documented proposal in `aws-validation.md`, not an
implemented mode.

#### Policy shape

`egress_firewall.policies` is keyed by policy name; `cluster_policy_key`
(default `cluster`) names the one the EKS workload subnets use and every
external `aws_egress_attachments[*].policy_key` must name an existing policy.
Each policy has:

- `domain_allow.<name>`: named rules, mirroring `network_allow`:

  ```hcl
  domain_allow = {
    vendor_api = {
      domains           = ["api.vendor.com", "*.vendor.com"]
      protocol          = "https"
      destination_ports = [443] # optional; defaults to 443 for https, 80 for http
    }
  }
  ```

  `domains` is a non-empty set of bare DNS names, exact (`api.example.com`)
  or leading-wildcard (`*.example.com`); `protocol` is required and is
  `https` (TLS SNI match) or `http` (HTTP `Host` match). The same protocol and
  port apply to every domain in the rule, and one Suricata rule is generated per
  domain with the stable identity
  `<class>/domain/<name>/<protocol>/<port>/<domain>`, so the same host under two
  rule names never collides. v1 accepts only `https`+443 and `http`+80; an
  explicit empty `destination_ports` or any other port is rejected at plan time
  until non-standard ports are validated separately. There is no `domain:port`
  syntax and no raw-rule input; a name on any other port needs a network rule.
  Wildcards are rejected when the suffix is a public suffix
  (`*.co.uk`, `*.xn--55qx5d.cn`), checked offline against the vendored,
  ASCII-normalised Public Suffix List (`egress_network/public_suffix_list.dat`,
  refreshed with `update_public_suffix_list.py`).
- `network_allow.<name>`: `destination_ipv4_cidrs`, `protocol` (`tcp`/`udp`),
  `destination_ports`, `reason`. IP exceptions on TCP 80/443 bypass
  Host/SNI matching entirely; the effective output flags them as
  `bypasses_domain_matching`.

The platform baseline (`platform_https_domains`) compiles separately as
`cluster/platform/https/443/<domain>` rules for the cluster class only; it is
never inherited by external attachments. A customer rule that repeats a
baseline host keeps its own identity, with `platform_required = true` in the
effective output, so removing the duplicate does not revoke platform access.
`default_action` accepts only `"deny"`.

The module compiles both kinds into one managed stateful rule group (capacity
30000, immutable after creation, consuming the default policy budget of one
group; more groups are a quota/review item). Plan-time preconditions reject
duplicate or reserved rule SIDs, more than 30000 rules, a rule over 8192 bytes
or a rule string over 2,000,000 bytes, and exact duplicate or overlapping
source CIDRs, before anything is mutated. `egress_firewall.effective_rules`
lists every generated rule by stable identity
(`<class>/domain/<name>/<protocol>/<port>/<domain>`,
`cluster/platform/https/443/<domain>`, `<class>/network/<name>`) with its SID, origin (`customer` or `platform`),
protocol/ports/destination and reason. `platform_required` and
`customer_configured` preserve both sources when the same allowance appears in
the baseline and customer policy; deleting a customer entry does not revoke a
platform-required allowance.

**Routing warning.** AWS Network Firewall only inspects a flow whose forward
and return packets pass through the same firewall endpoint
([asymmetric routing](https://docs.aws.amazon.com/network-firewall/latest/developerguide/asymmetric-routing.html)).
This module configures that routing for every protected subnet and AZ in one
resource graph; review each plan for route/association replacements, because
resource dependencies alone do not make a transition traffic-safe for nodes
that are already running (see the migration limitations in
`docs-internal/changes/cloud-egress-firewall/aws-validation.md`). Out-of-band changes to the routes, route-table associations, firewall
policy, firewall endpoints/interfaces, or any alternate egress (extra NAT,
IGW route, second NIC, IPv6) can bypass inspection or drop traffic, and
**default-deny is not a guarantee after such a change**. This is a measured
result, not a general AWS statement: in validation
(`aws-validation.md`, r3) deleting only the cluster's per-subnet return route in
one NAT table — everything else intact — let a fresh, normally-forbidden TLS
connection reach its origin and return HTTP 200. Keep protected routing and
policy under one Terraform owner, restrict changes to reviewed provisioning
and break-glass identities, alert on changes, and re-run allow/deny canaries
after any modification.

Ordinary symmetric routing is the supported v1 baseline. Re-pointing each NAT
table's AWS-created VPC-local route at the firewall endpoint (so the exact
deletion above fails closed) was prototyped in the standalone
`egress_network/fixtures/live` experiment (`adopt_nat_local_routes`) and is **not** part of the
supported root: it needs Terraform `import` blocks, which are root-only (a root
containing one cannot be consumed as a child module, and `import.for_each`
needs Terraform >= 1.7 where this module supports >= 1.5.7), and it does not
stop a privileged actor who can rewrite routes. If you applied that prototype
by hand, restore the route target to `local` (`ReplaceRoute`) **before**
removing the owning resource: AWS refuses to delete a local route and the
provider tolerates that error, so dropping the resource or its state leaves
the endpoint target in place (provider 6.66.0, r4/r5 fixtures).

Ownership:

| Concern | Module provides | Customer / account owner supplies |
|---------|-----------------|-----------------------------------|
| Topology | Firewall, per-AZ endpoints, NAT, all forward/return routes and associations for primary **and** every declared secondary VPC CIDR (Cilium pod CIDR), plan-time validation that protected subnets sit inside declared CIDRs and that the CNI is Cilium | No alternate egress in the VPC; secondary CIDR associations declared to the module |
| Policy | Suricata rule set generated from `egress_firewall.policies`; external attachments never inherit the cluster baseline; native alert + flow logs (`alert_log_group`, `flow_log_group`) | Reviewed policy changes through Terraform only. Traffic logs record what the firewall saw; they cannot show flows that bypassed it |
| Change protection | `change_protection` (default `true`) sets delete, subnet-change and policy-change protection on the firewall. AWS then rejects `DeleteFirewall`, subnet-mapping and policy-association changes, and the provider does **not** lift it: apply `change_protection = false` first when destroying or changing the AZ set, then restore. It protects the firewall object only: a `destroy` run against a protected firewall still removes routes, associations, NAT and logging before it fails on `DeleteFirewall`, so it is not a guard against a mistaken destroy of the network | Treat that flip as a break-glass change; protect the state/workspace against accidental `destroy` separately |
| Identifiers for monitoring | `egress_firewall` output: `firewall_arn`, `firewall_endpoints`, `nat_route_table_ids`, `cluster_subnet_ids` (the primary per-AZ workload subnets, the EKS/load-balancer selector), `protected_subnet_ids` (every subnet routed through the firewall, including additional workload subnets and attachments), `vpc_cidrs`, `effective_rules`, log groups; disabled mode returns the same object with `enabled = false`, empty maps/lists and null ARNs | CloudTrail/EventBridge alerts on `ec2:CreateRoute/ReplaceRoute/DeleteRoute`, `*RouteTableAssociation`, `network-firewall:Update*/Delete*`, `ec2:*VpcCidrBlock`, ENI attach on protected instances; a topology-aware drift check (reviewed `terraform plan` or a custom Config rule comparing routes to this output); a named remediation operator; allow/deny canaries after repair |
| Identities | Node, Karpenter, Cilium-operator and add-on IRSA roles carry only `ec2:Describe*` on route tables and no firewall permissions. The Ryvn agent executor role (`iam.tf`) defaults to `Allow *` minus data-plane denies, so it **can** rewrite routes and policy: it is the provisioning identity, not a workload one | Least-privilege workload and consumer roles with no route, association, firewall-policy or admin mutation; provisioning and break-glass identities reviewed ([IAM best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)). If you add IAM/SCP conditions, verify each EC2 action's supported resource types and condition keys in the Service Authorization Reference first — not every route/association action accepts `aws:ResourceTag` — and protect the tags themselves |

What AWS-managed controls do and do not cover here:

- [Security Hub Network Firewall controls](https://docs.aws.amazon.com/securityhub/latest/userguide/networkfirewall-controls.html)
  check logging, deletion protection and policy settings on the firewall. They
  do not evaluate VPC routes, so they cannot prove symmetric NAT return
  routing.
- [Firewall Manager route-table management](https://docs.aws.amazon.com/waf/latest/developerguide/fms-manage-vpc-route-tables.html)
  is a conditional option, not a fix for this topology: its Monitor mode
  currently covers internet-gateway traffic (not NAT or other gateway
  targets), excludes centralized route management, reports findings rather
  than repairing, and may take up to 12 hours to notice a disassociation.
- AWS's routing-enhancement material documents the local-route override
  prototyped above as a valid pre-NAT inspection option; nothing in AWS
  documentation describes it, or any of the above, as protection against an
  authorized actor rewriting routes.

Lifecycle: first create is a single apply (network before cluster; the Cilium
bootstrap's image pulls transit the firewall). Adding an AZ or destroying
requires `change_protection = false` in a preceding apply; the shipped
provision/deprovision policies (`infra/perms/aws/permissions`, mirrored to
`repos/environments/aws-eks-byoc/permissions`) carry the
`network-firewall:Update*Protection`, `AssociateSubnets`/`DisassociateSubnets`,
`ListRuleGroups` (the provider lists rule groups while creating the policy) and
`ec2:ReplaceRoute` actions this needs, so it does not depend on an admin
identity. The private default route of each cluster route table is one root
resource in both modes (`aws_route.private_default`, NAT target when disabled,
AZ-local firewall endpoint when enabled), so a mode switch replaces the target
in place instead of racing two owners for the same `0.0.0.0/0`. Routing
cutovers on a live environment are still not traffic-neutral: enabling or
disabling replaces NAT gateways, public egress IPs and route-table
associations, and a disable run must be preceded by `change_protection = false`
or it removes the routes and NAT before failing on `DeleteFirewall`. Disabling
also deletes the firewall log groups; export the alert/flow evidence first.
The current boolean input does not expose build-only or per-AZ cutover stages.
An existing environment needs a reviewed maintenance plan and rollback; see
the migration section of
`docs-internal/changes/cloud-egress-firewall/aws-validation.md`.

Activation order: this module merges and ships with `enabled = false`, which
leaves the existing egress path alone. Turning it on needs a healthy Cilium
ENI dataplane already running on the cluster (ENI IPAM from the protected
cluster subnets, native routing, kube-proxy retained, no prefix delegation);
`cni = "cilium"` only creates the operator IRSA role and does not install or
verify Cilium, so setting it is not enough. Establish and verify that dataplane
first, through whichever bootstrap workflow the environment uses. If the
`ryvn-init` CodeBuild launcher is composed into this root, it must be
placed with `subnet_ids = local.node_subnet_ids` so the bootstrap job waits
for the firewall routes exactly as the node groups do. Any apply that flips
`enabled` is a maintenance event: isolate traffic, expect minutes of egress
loss per AZ and, if the apply fails part-way, a temporary loss of enforcement
or connectivity until it is rolled forward or back; re-run allow/deny canaries
after convergence before treating the environment as protected.

#### Example: hosting a Tailscale peer relay (no dedicated setting)

A customer running Tailscale participants (operator, `PeerRelay`, app sidecars)
in protected subnets uses the ordinary policy inputs; the firewall has no
Tailscale toggle and grants no UDP by itself. Stage it in two applies so the
network never depends on a Kubernetes Service the same environment creates:

```hcl
# 1. Coordination/DERP over TLS 443. Either the customer-chosen suffix below or
#    the exact names (controlplane/login/log.tailscale.com plus the DERP
#    hostnames from the tailnet's effective DERP map; derpN-all aliases are
#    DNS/IP aliases, not the SNI the firewall sees).
domain_allow = {
  tailscale_control = { domains = ["*.tailscale.com"], protocol = "https" }
}

# 2. After the PeerRelay's NLB exists: its public IPv4 addresses (or
#    pre-allocated EIPs), UDP 41641 (operator 1.102.4 has no spec.service.port).
#    Both sides of a relayed connection, including pods in this cluster, send
#    UDP to that public address, so it is ordinary inspected egress even though
#    the targets are private pod IPs. Replacing the NLB means updating this rule;
#    nothing discovers the addresses for you. Supply the actual public /32s
#    through tailscale_relay_public_ipv4_cidrs; documentation/private ranges
#    are rejected by the module.
network_allow = {
  tailscale_peer_relay = {
    destination_ipv4_cidrs = var.tailscale_relay_public_ipv4_cidrs
    protocol               = "udp"
    destination_ports      = [41641]
    reason                 = "in-cluster Tailscale peers bind to the hosted relay"
  }
}
```

STUN (UDP 3478) and direct peer UDP stay denied unless added. The Tailscale
integration owns the NLB, target group and health checks; this module owns the
routes and the compiled policy; the customer owns tailnet grants. Keep the relay
and the pods that use it on different workers until the same-worker NLB hairpin
path is verified
([NLB troubleshooting](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-troubleshooting.html)).
Validation so far covers DERP and UDP echo through an NLB, not a peer-relay
session (`aws-validation.md`).

#### Changes requiring migration

These inputs are intentional one-way or replacement decisions; the plan shows
the replacement, but the cost is only visible if you know to look:

| Change | Effect |
|--------|--------|
| Renaming an `aws_egress_attachments` key or an AZ key under `subnets_by_az`, or changing a subnet CIDR | Subnet, route table and association are replaced (new state addresses); compute in that subnet must move first |
| Raising `workload_subnets_per_az` | Additive, as long as nobody took the reserved growth slots. The module refuses attachment CIDRs inside any existing **or future** cluster slot (for the default `/16`: `/20`s 0–12); free examples are `10.0.208.0/24`, `10.0.209.0/24` |
| Enabling/disabling the firewall, or changing the AZ set | Replaces NAT gateways and public egress IPs (`outbound_ips`); downstream allow-lists keyed on those IPs break. Rehearsed on `egfw-r8`: minutes of egress loss per direction, and a disable attempted against a protected firewall stops half-way (fail-open on the single NAT until rolled forward or back) |
| Disabling the firewall | Also deletes the Network Firewall alert/flow log groups with their retained evidence |
| Rule-group capacity | Internal, fixed at 30000, immutable after creation; a change means a new rule group and policy update |
| Enabling the firewall on a VPC with the S3 gateway endpoint | The endpoint is removed; S3 traffic moves to the inspected NAT path and bucket policies conditioned on `aws:SourceVpc` stop matching |
| `change_protection` | Protects the firewall object only (see the ownership table); it does not protect routes, associations, NAT or the network as a whole |
| Tightening an existing wildcard (`*.example.com` -> exact names) | Safe to plan, but live clients on the removed names lose connectivity at apply; stage it with the effective-rule output and alert logs |

## Key Variables

| Name | Description | Default |
|------|-------------|---------|
| `environment_name` | Environment name, used as a suffix throughout | required |
| `account_id` | AWS account to provision into | required |
| `region` | AWS region | `"us-east-1"` |
| `public_root_domain` / `internal_root_domain` | Domains for the Route 53 zones | required |
| `cluster_version` | EKS Kubernetes version | `"1.34"` |
| `vpc_cidr` | CIDR for the VPC when the module creates it | `"10.0.0.0/16"` |
| `workload_subnets_per_az` | Workload subnets per AZ (1–4); raise it to add IP capacity | `1` |
| `existing_vpc_id` | Provision into an existing VPC | `null` |
| `existing_workload_subnet_ids` | Run nodes in pre-existing subnets, creating no topology | `[]` |
| `egress_mode` | `create_nat`, `nat_gateway` or `transit_gateway` | `"create_nat"` |
| `create_s3_gateway_endpoint` | Create an S3 gateway endpoint on the private route table; `null` means on for a Ryvn-provisioned VPC, off for BYO | `null` |
| `s3_gateway_endpoint_policy` | Endpoint policy JSON; `null` keeps AWS's allow-all default | `null` |
| `create_cluster_kms_key` | Use a customer-managed KMS key as the envelope-encryption KEK | `true` |
| `eks_managed_node_groups` | Node group overrides, merged with the defaults | `{}` |
| `cluster_addons` | Add-on overrides, merged with the defaults | `{}` |
| `cni` | Target CNI; `cilium` adds the Cilium operator's IRSA role and nothing else — it does not install or verify Cilium. Required by an enabled `egress_firewall` | `"vpc-cni"` |
| `egress_firewall` | Managed default-deny egress (`enabled`, `policies`, `cluster_policy_key`, `change_protection`); see [Managed egress firewall](#managed-egress-firewall-egress_firewallenabled--true) | `{ enabled = false }` |
| `aws_egress_attachments` | Additional protected workload subnets for customer compute, keyed by class and AZ, each bound to a named policy; requires the firewall to be enabled | `{}` |
| `cluster_access_entries` | Extra EKS access entries | `{}` |
| `pod_identity_associations` | Extra Pod Identity associations | `{}` |
| `terraform_executor_policies` | Replace the Ryvn agent's default IAM policy | `[]` |
| `iam_permissions_boundary_arn` | Permissions boundary for every role created | `null` |
| `cluster_endpoint_public_access_cidrs` | Additional CIDRs allowed on the public API endpoint | `[]` |
| `skip_dns_provisioning` | Skip both Route 53 zones | `false` |

See `variables.tf` for the full set, including the `byo_*_subnet_cidrs`
overrides used when the head of a VPC's range is already occupied.

## Outputs

`cluster_*` (endpoint, CA data, name, OIDC issuer, version, status, region),
`vpc` (a map of ids, CIDRs, AZs, subnet ids and the S3 gateway endpoint id), `karpenter`, `public_domain`,
`internal_domain`, `outbound_ips` and `outbound_ips_known`, the IAM role ARNs
for each component, `addons` (per-addon IRSA role ARNs),
`cluster_secrets_encryption` and `control_plane_logging`.

`outbound_ips_known` distinguishes "this environment has no public egress
addresses" from "its egress is centralized and the addresses live elsewhere" —
consumers should not read an empty `outbound_ips` as the former.

## One-Way Decisions

The VPC CIDR and subnet layout, the cluster name (derived from
`environment_name`), and the choice of envelope-encryption key cannot be
changed in place. Switching between networking modes on a live environment
means replacing the cluster. `workload_subnets_per_az` can be raised but not
lowered.

## Tests

`tests/byo_subnet_azs` is a self-contained mirror of the AZ-uniqueness logic in
`network.tf`, exercised without any provider credentials:

```bash
cd tests/byo_subnet_azs && terraform init -backend=false && terraform test
```

`tests/workload_subnets.tftest.hcl` plans the whole module against mock
providers:

```bash
terraform init -backend=false -upgrade && terraform test
```

`tests/child_module` consumes this root as a child module. Its `init` fails on
any root-only block (`import`, backend) that the root's own tests cannot see:

```bash
cd tests/child_module && terraform init -backend=false && terraform validate
```

`egress_network/tests/contract.tftest.hcl` covers the rule compiler and subnet
contract (`cd egress_network && terraform init -backend=false && terraform
test`).

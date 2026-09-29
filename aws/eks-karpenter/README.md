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
- **Cilium** (`cni = "cilium"`): no VPC CNI add-on; `ryvn-init` installs
  Cilium from a CodeBuild run inside the VPC that the apply starts and waits
  for. See [Cilium bootstrap](#cilium-bootstrap).
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

Optional default-deny public IPv4 egress for a Ryvn-provisioned VPC: each
private subnet routes `0.0.0.0/0` through an AZ-local AWS Network Firewall
endpoint, then an AZ-local NAT gateway; exceptions are named hostname
(SNI/Host on 443/80) and narrow IP/port rules, compiled into one policy with a
cluster-only platform baseline. Ryvn-owned external subnet groups
(`additional_subnet_groups`) can be assigned a policy with
`egress_attachments`; nothing here accepts customer-chosen CIDRs.

The module ships with `enabled = false` and leaves the legacy network (single
NAT, one private route table, S3 gateway endpoint) alone. Enabled mode
requires `cni = "cilium"` and supports only a healthy Cilium ENI dataplane: a
new environment sets both from the first apply and bootstraps Cilium inside
the protected topology, an existing VPC-CNI environment needs a coordinated
CNI migration. `ryvn-init` installs Cilium in the same apply (see [Cilium
bootstrap](#cilium-bootstrap)). Enabling or disabling replaces NAT gateways,
public egress IPs and route ownership and removes the S3 gateway endpoint, so
on an existing environment it is a reviewed maintenance event, not a toggle.

- Feature and module reference (architecture, policy semantics, routing
  symmetry and drift warnings, `change_protection` scope, lifecycle and
  migration table, evidence boundaries, Tailscale example):
  [`egress_network/README.md`](egress_network/README.md).
- `additional_subnet_groups` sizing and append-only allocation guard:
  [`workload_subnet_groups/README.md`](workload_subnet_groups/README.md)
  (the directory keeps its original name; the public input and output are
  `additional_subnet_groups`).
- Internal per-customer setup and verification procedure:
  `docs-internal/guides/aws-egress-firewall-runbook.md`; design contract in
  `docs-internal/changes/cloud-egress-firewall/`.

## Key Variables

| Name | Description | Default |
|------|-------------|---------|
| `environment_name` | Environment name, used as a suffix throughout | required |
| `account_id` | AWS account to provision into | required |
| `region` | AWS region | `"us-east-1"` |
| `public_root_domain` / `internal_root_domain` | Domains for the Route 53 zones | required |
| `cluster_version` | EKS Kubernetes version | `"1.34"` |
| `vpc_cidr` | CIDR for the VPC when the module creates it | `"10.0.0.0/16"` |
| `workload_subnets_per_az` | Cluster workload subnets per AZ (1–4); raise it to add node/pod IP capacity inside the cluster's discovery, routing and policy | `1` |
| `existing_vpc_id` | Provision into an existing VPC | `null` |
| `existing_workload_subnet_ids` | Run nodes in pre-existing subnets, creating no topology | `[]` |
| `egress_mode` | `create_nat`, `nat_gateway` or `transit_gateway` | `"create_nat"` |
| `create_s3_gateway_endpoint` | Create an S3 gateway endpoint on the private route table; `null` means on for a Ryvn-provisioned VPC, off for BYO | `null` |
| `s3_gateway_endpoint_policy` | Endpoint policy JSON; `null` keeps AWS's allow-all default | `null` |
| `create_cluster_kms_key` | Use a customer-managed KMS key as the envelope-encryption KEK | `true` |
| `eks_managed_node_groups` | Node group overrides, merged with the defaults | `{}` |
| `cluster_addons` | Add-on overrides, merged with the defaults | `{}` |
| `cni` | Target CNI; `cilium` drops the VPC CNI add-on and bootstraps Cilium with `ryvn-init`. Required by an enabled `egress_firewall` | `"vpc-cni"` |
| `ryvn_init_image` / `cilium_chart_version` | Bootstrap image and Cilium chart version used in `cilium` mode | `null`; required with `cilium`, set by the platform blueprint |
| `cilium_repair` | Force reinstall Cilium, even if a Ryvn installation has adopted it | `false` |
| `ryvn_init_migration_timeout_seconds` | Extra time to move existing nodes from the VPC CNI to Cilium | `10800` |
| `egress_firewall` | Managed default-deny egress (`enabled`, `policies`, `cluster_policy_key`, `change_protection`); see [`egress_network/README.md`](egress_network/README.md) | `{ enabled = false }` |
| `platform_https_domains` | Extra exact HTTPS/443 hostnames the platform components reach (managing hub API/issuer/token, collector gateways, access tunnel). Added to the built-in AWS/registry baseline (never replacing it), cluster sources only; bare lower-case hostnames, no scheme/path/port/wildcard/IP. The Ryvn AWS blueprint fills this from the managing hub; standalone callers list them. Ignored while disabled | `[]` |
| `additional_subnet_groups` | Ordered, append-only list of named Ryvn-owned subnet groups for compute **outside** the cluster (`name`, `ipv4_prefix_length`, explicit `availability_zones`, `retired`); one subnet + dedicated local-only route table per group and AZ, no cluster/Karpenter/Cilium discovery, created whether or not the firewall is enabled, allocated from a reserved area separate from the cluster's; see [`workload_subnet_groups/README.md`](workload_subnet_groups/README.md) | `[]` |
| `egress_attachments` | Named external compute classes: `{ subnet_group_key, policy_key }` assigns one group to one policy (inspected routes + source rules). No CIDRs, no subnet creation; requires the firewall to be enabled | `{}` |
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
`cluster_secrets_encryption`, `control_plane_logging`, `egress_firewall`
(configured policy, `effective_rules`, `attachments`, firewall/NAT identifiers;
the same shape with `enabled = false` when disabled) and `additional_subnet_groups`
(per-group native subnet inventory); both are described in
[`egress_network/README.md`](egress_network/README.md).

`outbound_ips_known` distinguishes "this environment has no public egress
addresses" from "its egress is centralized and the addresses live elsewhere" —
consumers should not read an empty `outbound_ips` as the former.

## Cilium Bootstrap

- With `cni = "cilium"` the cluster gets no `vpc-cni` add-on, and new nodes
  carry the `node.cilium.io/agent-not-ready` taint until Cilium runs on them
  (managed node groups here, Karpenter node pools through the platform
  blueprint).
- [`modules/ryvn-init`](modules/ryvn-init/README.md) installs Cilium from a
  CodeBuild run inside the VPC, so nothing outside the VPC calls the cluster
  API. The apply waits for it and stops with the reason on failure; changing
  the image, chart version or values runs it again.
- Changing `cni` from `vpc-cni` to `cilium` on an existing cluster moves its
  nodes to Cilium one at a time in the same apply (cordon, drain, hand over,
  uncordon). If `ryvn_init_migration_timeout_seconds` runs out first, the next
  apply continues.
- If the CNI breaks, apply with `cilium_repair = true`, then set it back to
  `false`.

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

`egress_network/tests/` covers the rule compiler and subnet contract, and
`workload_subnet_groups/tests/` the allocator and geometry guard (`terraform
init -backend=false && terraform test` in each directory).

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
  gateway, optional flow logs and optional transit gateway landing-pad subnets.
- **Cluster**: EKS with a private endpoint plus a public endpoint restricted to
  the Ryvn control plane and any CIDRs you allow, control-plane logging, IRSA
  and Pod Identity, and envelope encryption with a customer-managed KMS key by
  default.
- **Node groups**: a small `CriticalAddonsOnly` system group for the components
  Karpenter itself depends on; all other capacity comes from Karpenter.
- **Add-ons**: VPC CNI, CoreDNS, kube-proxy, EBS CSI, EFS CSI, Pod Identity
  agent, and Karpenter's controller IAM role and interruption queue.
- **IAM**: roles for the Ryvn agent, external-dns, cert-manager, the AWS Load
  Balancer Controller, and cluster-autoscaler (opt-in). Every role can carry a
  permissions boundary.
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

## Key Variables

| Name | Description | Default |
|------|-------------|---------|
| `environment_name` | Environment name, used as a suffix throughout | required |
| `account_id` | AWS account to provision into | required |
| `region` | AWS region | `"us-east-1"` |
| `public_root_domain` / `internal_root_domain` | Domains for the Route 53 zones | required |
| `cluster_version` | EKS Kubernetes version | `"1.34"` |
| `vpc_cidr` | CIDR for the VPC when the module creates it | `"10.0.0.0/16"` |
| `existing_vpc_id` | Provision into an existing VPC | `null` |
| `existing_workload_subnet_ids` | Run nodes in pre-existing subnets, creating no topology | `[]` |
| `egress_mode` | `create_nat`, `nat_gateway` or `transit_gateway` | `"create_nat"` |
| `create_cluster_kms_key` | Use a customer-managed KMS key as the envelope-encryption KEK | `true` |
| `eks_managed_node_groups` | Node group overrides, merged with the defaults | `{}` |
| `cluster_addons` | Add-on overrides, merged with the defaults | `{}` |
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
`vpc` (a map of ids, CIDRs, AZs and subnet ids), `karpenter`, `public_domain`,
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
means replacing the cluster.

## Tests

`tests/byo_subnet_azs` is a self-contained mirror of the AZ-uniqueness logic in
`network.tf`, exercised without any provider credentials:

```bash
cd tests/byo_subnet_azs && terraform init -backend=false && terraform test
```

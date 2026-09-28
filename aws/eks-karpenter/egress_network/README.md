# egress_network

Child module behind `egress_firewall.enabled = true` in `aws-provision-karpenter`:
AWS Network Firewall + per-AZ NAT with default-deny public IPv4 egress and a
Suricata rule set generated from the common `egress_firewall` policy contract
(`docs-internal/changes/cloud-egress-firewall/contract.md`).

Routing, ownership, change-protection lifecycle and the measured
route-deletion result are documented once, in the parent README's
[Managed egress firewall](../README.md#managed-egress-firewall-egress_firewallenabled--true)
section. Read it before changing `main.tf` routes or applying against a live
environment.

Inputs that decide coverage:

- `vpc_cidr` + `vpc_cidrs`: every CIDR associated with the VPC. Protected
  subnets must fall inside one of them; each AZ NAT table gets one entry in
  `nat_local_routes` per CIDR (audit identifiers for drift checks; the module
  never owns those local routes).
- `cluster_subnets_by_az` / `cluster_source_cidrs_by_az`: node and (secondary
  CIDR) pod subnets that form the cluster source class and `HOME_NET`.
- `attachments`: optional protected workload subnets for customer compute.
  The module creates each requested subnet, route table and association (one
  per named class and AZ, never per VM); the caller owns what runs there.
  They never receive the cluster baseline.
- `change_protection`: defaults `true`; set `false` in the apply before a
  destroy or AZ change (the provider does not lift it for you).

Deterministic tests: `terraform test` in this directory (mock providers).
Disposable cloud fixtures live under `fixtures/`; they set
`change_protection = false` so teardown needs no extra apply.

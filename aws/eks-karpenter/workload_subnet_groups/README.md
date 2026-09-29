# additional_subnet_groups (module directory `workload_subnet_groups/`)

Network-layer child module of `aws-provision-karpenter` behind the root input
and output `additional_subnet_groups`: allocates and creates named Ryvn-owned
subnet groups for compute outside the cluster (one subnet, dedicated route
table and association per group and AZ) independently of
`egress_firewall.enabled`. It is the only place the sizing and stability rules
live; the firewall reference
([`../egress_network/README.md`](../egress_network/README.md)) links here.

Not to be confused with `workload_subnets_per_az`, which grows the cluster's
own node/pod subnets inside cluster discovery, routing and policy. Both are
Ryvn-owned allocations from separate reserved areas of the VPC: cluster
subnets and growth slots occupy VPC blocks 0-12 (and 15), these groups
blocks 13-14.

Maintainer note: the directory and the internal label
`module.workload_subnet_groups[0]` predate the public name and are kept so
no state address changes; all state snippets below use the internal label.

## Interface

| Input | Meaning |
|-------|---------|
| `name`, `vpc_id`, `vpc_cidr`, `azs`, `tags` | Environment identity; `azs` is the environment's selected AZ set, which every group's `availability_zones` must be a duplicate-free subset of |
| `reserved_cidrs` | Existing and reserved subnet CIDRs (cluster, public, intra, NAT, firewall, growth slots) that no group may overlap; a real overlap fails the plan |
| `groups` | Ordered, append-only ledger: `{ name, ipv4_prefix_length, availability_zones, retired = false }`. Unique names, `cluster` reserved. The root passes `var.additional_subnet_groups` through unchanged |

| Output | Meaning |
|--------|---------|
| `geometry` | Calculated allocation per group, retired included (`position`, `ipv4_prefix_length`, `availability_zones`, `cidrs_by_az`); plan-known |
| `groups` | Active groups keyed by name with `subnets_by_az[az] = { subnet_id, ipv4_cidr, route_table_id }`. Inventory only, not a readiness token |
| `active_cidrs`, `subnet_ids` | Active subnet CIDRs in allocation order; subnet IDs keyed `group/az` |

## Allocation

```text
cidrsubnets(vpc_cidr,
  4 ×13,                                # blocks 0–12: the cluster's existing and future layout
  (g.ipv4_prefix_length - vpc_prefix)   # one request per group and AZ, in list order,
   for g in groups for az in g.azs)     #   retired entries included
block 15 (prefix VPC+4) is reserved: any request reaching it fails the plan
```

Consequences on the default `10.0.0.0/16`:

- blocks 13–14 (`10.0.208.0`–`10.0.239.255`, two `/20`s) are the whole external
  budget; `api_clients` `/24 × 3` gets `10.0.208.0/24`, `10.0.209.0/24`,
  `10.0.210.0/24`, then `small_jobs` `/26 × 2` gets `10.0.211.0/26`,
  `10.0.211.64/26`; a three-AZ `/20` request fails at plan;
- `ipv4_prefix_length` is an integer from `max(16, VPC+4)` to 28; alignment
  gaps consume budget;
- there is no silent VPC resizing, no borrowing of cluster growth slots
  (`workload_subnets_per_az` can still be raised), no sorted-map indexing,
  hash/probe allocator or live first-free lookup. Rationale:
  [HashiCorp `cidrsubnets` guidance](https://github.com/hashicorp/terraform-cidr-subnets#changing-networks-later).

## Stability guard

One `terraform_data` record per group (retired included) stores
`{position, ipv4_prefix_length, availability_zones, cidrs_by_az}` on first
apply with `ignore_changes = [input]` and `prevent_destroy = true`; a
postcondition compares the recorded output with the recalculated geometry and
fails the plan on any difference. Subnets consume the recorded CIDRs, so a
failed guard blocks every dependent change; the subnet CIDRs themselves are
not `ignore_changes`, and the AWS subnet/route resources carry no
`prevent_destroy` (retirement must still remove them).

Because `cidrsubnets` allocates sequentially in list order, an entry's
addresses depend on every entry before it. Removing or renaming an entry
therefore both destroys its record (rejected outright by `prevent_destroy`
while the module is in the configuration) and shifts every later entry
(rejected by the surviving records' geometry postconditions). Retirement is
the only supported way to stop using a group: the tombstone and its span are
permanent, it never frees budget for new groups, and the entry cannot be
deleted afterwards. The same entry can be un-retired unchanged.

These are configuration-level protections: `terraform state rm`, removing the
module block, or editing state bypass them. They stop accidental plans, not a
determined operator.

| Change | Effect |
|--------|--------|
| Append a group at the end | Safe; earlier groups keep IDs and CIDRs (also when the new name sorts first) |
| Edit, reorder, resize or change the AZ list/order of an applied entry | Rejected by the guard. Append a new group, migrate compute, then retire the old one |
| `retired = true` (after the attachment and its compute are gone) | Subnets and route tables are removed; the span stays reserved; later groups are unchanged. Never compact |
| Remove, rename or clear any entry (active or retired), including the last one | Rejected: `prevent_destroy` on the entry's record, plus geometry failures on every later record. Not a reclaim path |
| Delete a record from state (`terraform state rm`) or drop the module block | Bypasses both protections: the allocator cannot see history it no longer has, so later groups shift and are replaced on the next apply. Only done as part of a full teardown (below) |
| Upgrade from a state where the firewall child owned attachment subnets (`module.egress_network[0].aws_subnet.worker["<class>/<az>"]` + `aws_route_table.worker` + `aws_route_table_association.worker`) | Declare a group whose position and prefix reproduce the occupied CIDRs, then `terraform state mv` each of the three resources per AZ to `module.workload_subnet_groups[0].{aws_subnet,aws_route_table,aws_route_table_association}.group["<group>/<az>"]` before applying. No generic `moved` block exists because source keys are per-fixture; without the moves the plan replaces the subnets. The sequence run on `egfw-r8` is in `docs-internal/changes/cloud-egress-firewall/aws-validation.md` |

Group subnets carry no cluster, Karpenter, Cilium or load-balancer discovery
tags and have only the VPC-local route until an `egress_attachments` entry
assigns them a policy (see the firewall reference). Retirement removes them
without a firewall change; the attachment must already be gone.

## Full-environment teardown

`prevent_destroy` also blocks `terraform destroy` while any group has ever
been applied. Tearing an environment down is a deliberate, separate procedure,
not an ordinary apply and not a way to reclaim one group's range:

1. Stop and coordinate every concurrent apply against the environment; back up
   the state.
2. List only the bookkeeping addresses:
   `terraform state list | grep 'module.workload_subnet_groups\[0\].terraform_data.geometry\['`.
   Never touch `aws_*` addresses.
3. Forget those records: `terraform state rm <address>` for each. The
   reservations are now gone from state; do **not** run a normal apply from
   here (it would rewrite the ledger from scratch).
4. Generate and review a fresh destroy plan for the remaining real
   infrastructure, then apply it in the same window.

The egress firewall's `change_protection` is independent of this and still has
to be lowered in a preceding apply; forgetting the geometry records does not
bypass AWS object protection. The Ryvn deprovisioner is unchanged by this
module.

Tests: `terraform init -backend=false && terraform test` here (stateful
append/retire/guard/exhaustion cases with mock providers), plus
`tests/prevent_destroy.sh` (offline, provider never called: removal/rename/
clear/tombstone deletion rejected, append and retirement still apply, destroy
blocked until the geometry records are forgotten).

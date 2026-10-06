# Native GCP egress configuration and activation

This module owns native Cloud NGFW Enterprise URL filtering for the
[parent GCP GKE platform](../../README.md). The parent enables it only when
`egress_firewall.enabled = true`; filtering is disabled by default. A parent
module upgrade alone does not enable it, but can reconcile unrelated GKE
settings: review the entire upgrade plan.

**Do not treat first activation as a zero-downtime change.** A controlled
existing-environment test observed fresh allowed HTTPS and collector token
refresh impairment during an approximately 55-minute activation task window.
This is an approximate observation, not an exact uninterrupted per-workload
outage or an SLA. Reserve **at least an hour plus contingency**; there is no
promised upper bound. Steady-state ordinary policy checks passed in the tested
active zones, but that does not establish availability for every deployment.

## What is enforced

The native path is workload → VPC firewall policy → zonal Google-managed web
inspection endpoint → normal internet route → existing root Cloud NAT → origin.
Direct tuple exceptions skip inspection. The existing root reserved NAT address
and Terraform resource identity do not depend on firewall enablement; web and
tuple traffic share it. Verify the address **allocation ID and receiver-observed
IP**, not just `outbound_ips`, after activation and policy updates. Google API
traffic is a separate routing case described below.

The cluster source class includes node-primary and pod ranges, including
host-network sources. Actual node, pod, service, additional subnet and Private
Service Access (PSA) destination ranges are allowed internally without URL
inspection; this is not an intra-VPC isolation feature. Metadata/link-local is
platform traffic outside the internet-domain contract. IPv6 internet has no
allow path. Existing Kubernetes network policies remain independent controls;
a pod timeout alone cannot attribute a drop to NGFW.

| Policy behavior | Scope / limitation |
|---|---|
| `https` domain allow | Visible TLS SNI on TCP/443; no TLS decryption |
| `http` domain allow | HTTP Host on TCP/80 |
| Exact name / leading wildcard | `*.example.com` matches `a.example.com` and `a.b.example.com`, **not** `example.com` or `notexample.com`; add the apex explicitly if needed |
| `network_allow` | Exact public IPv4 CIDR + TCP/UDP + explicit ports; **bypasses domain checks**, including a tuple on port 80 or 443 |
| Other public traffic | L4 final deny, subject to the native web inspection and coverage limitations below |

Domain syntax is lowercase DNS names, exact or leading `*.` only: no URL,
path, port, IP literal or trailing dot. HTTP ports must be `[80]`, HTTPS `[443]`
if specified. Avoid public-suffix wildcards such as `*.com` and multi-tenant
wildcards: the schema accepts them, but they can admit unrelated destinations.
Tuples require normalized public IPv4 CIDRs and a nonempty reason; private,
reserved, documentation and link-local ranges are rejected. UDP/443 tuples
are rejected; QUIC has no domain inspection path.

### Native limitations

Ordinary HTTP/HTTPS allow/deny and wildcard behavior do not imply complete
application-aware default drop. Controlled tests reproduced these bypasses:

- Forged allowed Host or SNI to an unrelated controlled destination can pass;
  neither field authenticates destination ownership.
- Plaintext HTTP with an allowed Host on TCP/443 can pass. Port 443 is not an
  HTTPS-only guarantee.
- Missing/empty Host, malformed HTTP, CONNECT and raw TCP/443 can pass despite
  final URL deny. There is no universal missing-domain/non-web denial guarantee.
- Loss of an endpoint association, or traffic from an uncovered zone, can
  bypass inspection. API readiness does not provide runtime fail-closed behavior.

There is no Secure Web Proxy (SWP) in this release, no TLS decryption, no
destination-ownership verification and no AWS/Azure parity claim. ECH/ESNI is
not supported by the visible-name domain contract. Direct-IP/no-SNI TLS was
blocked in the existing-environment probes, but this is not a universal no-SNI
guarantee. See Google's [Host/SNI and uncovered-zone behavior](https://docs.cloud.google.com/firewall/docs/about-url-filtering)
and [URL matcher documentation](https://docs.cloud.google.com/firewall/docs/configure-urlf-security-profiles).

## Parent interface: environment/root configuration

For a Ryvn-managed environment, set the policy in **environment configuration**;
the [GCP platform blueprint](../../../../ryvn-iac/blueprints/gcp-platform.blueprint.yaml)
forwards it to the `gcp-gke` installation and derives managing hub, issuer,
tunnel and collector HTTPS hosts. Do not apply a detached Terraform copy as a
substitute for updating the managed environment.

The following configures the **parent/root interface** through a **Ryvn CLI
patch-file fragment**, not the child module, a complete Environment manifest
or Terraform `.tfvars` file. `spec.config` is a YAML **mapping**, not a
block string. Merge it with the environment's reviewed current configuration;
preserve region, ranges, node pools, zones and all unrelated settings.

```yaml
spec:
  config:
    # Add only management APIs the cluster's provisioner actually needs.
    platform_https_domains:
      - compute.googleapis.com
      - cloudkms.googleapis.com
    egress_firewall:
      enabled: true
      default_action: deny
      cluster_policy_key: cluster
      policies:
        cluster:
          domain_allow:
            application_api:
              domains: [api.example.com, "*.feeds.example.com"]
              protocol: https
              destination_ports: [443]
          network_allow:
            cert_manager_dns_udp:
              destination_ipv4_cidrs: [8.8.8.8/32, 1.1.1.1/32]
              protocol: udp
              destination_ports: [53]
              reason: "cert-manager DNS-01 self-checks via blueprint public resolvers"
            cert_manager_dns_tcp:
              destination_ipv4_cidrs: [8.8.8.8/32, 1.1.1.1/32]
              protocol: tcp
              destination_ports: [53]
              reason: "cert-manager DNS-01 self-check TCP fallback"
```

Replace the example domains with required destinations. The
[platform blueprint](../../../../ryvn-iac/blueprints/gcp-platform.blueprint.yaml)
configures cert-manager's DNS-01 self-checks to query **both** `8.8.8.8:53` and
`1.1.1.1:53` directly. Keep these exact UDP/TCP DNS allowances when using that
configuration, and check certificate issuance/renewal after activation. They
are not required for ordinary in-cluster DNS; omit or replace them only if the
reviewed certificate/resolver configuration does not need those destinations.
The built-in HTTPS domain baseline does not add these public DNS tuples.
`platform_https_domains`
is additive to the built-in baseline and permits exact HTTPS/443 names for
cluster sources only. Application API domains belong in the workload's selected
policy. For standalone Terraform callers of the **parent/root module only**,
the mapping under `spec.config` supplies root Terraform input values; omit the
`spec.config` wrapper and supply explicit platform hosts that the blueprint
would otherwise derive. Do not pass the root `egress_firewall` object directly
to the child module; its interface is described below.

Root input types and validation are in [variables.tf](../../variables.tf), with the
[generated environment-config schema](../../../../frontend/src/schemas/terraform/ryvn-gke-provider/schema.json).
Terraform is authoritative for cross-field/CIDR validations not expressible in
that schema. The CLI wrapper is documented in
[update environment](../../../../cmd/cli/cmd/update.go); for a complete resource
manifest, see the [GCP Environment example](../../../../docs/iac/environments/gcp.mdx).

### Google APIs and private services

The [built-in platform baseline](../../egress_firewall.tf) includes GKE/autoscaling,
logging/monitoring/tracing, token exchange, common registries and storage,
DNS/certificate issuance APIs over HTTPS. Public recursive DNS requires separate
tuples as above. The baseline does **not** include every Terraform management
or application API. Inventory the APIs actually used by the environment and
its provisioner. Examples include `compute.googleapis.com`,
`networksecurity.googleapis.com`, `cloudresourcemanager.googleapis.com`,
`iam.googleapis.com`, `serviceusage.googleapis.com`, `sqladmin.googleapis.com`
and `cloudkms.googleapis.com`; allow only the appropriate names, not a broad
`*.googleapis.com`. Reachability and IAM authorization are separate requirements.

Private Cloud SQL or Redis data connections can use the allowed VPC/PSA ranges
when their actual endpoint addresses and routes are covered. Their management
APIs, connector/authentication dependencies and any application APIs still
need the appropriate domain allowances. Verify actual SQL/Redis operations in
each adopting environment. They were absent in the existing-environment
validation, so those service checks were N/A, not passes; no other customer
deployment is implied tested.

Do **not** infer that `private_ip_google_access = false` forces Google API
traffic through public NAT. The module sets the subnet flag false while NGFW
is enabled, but Cloud NAT automatically enables effective Private Google
Access on NAT-covered primary/secondary ranges; select Google API addresses
are not translated by Public NAT. See [Google's NAT/PGA interactions](https://docs.cloud.google.com/nat/docs/nat-product-interactions#private_google_access_interactions).
The native inspection rule has no `INTERNET`-only context restriction because
global Google APIs can be classified as `NON_INTERNET`; see
[network contexts](https://docs.cloud.google.com/firewall/docs/understand-network-contexts).
Validate actual API decisions from protected sources and native logs; hub-side
executor success and public-origin NAT receipts do not prove Google API routing.

## Child module interface and ownership

The [parent wiring](../../egress_firewall.tf) creates `module.egress_firewall`
only when filtering is enabled. The root owns the VPC, primary/secondary and
optional additional subnets, PSA allocation, Cloud Router, Cloud NAT and its
reserved address. It also owns root input validation, platform-baseline
assembly, source-class construction and NAT coverage. This child creates
native firewall policies/rules and their VPC association, zonal inspection
endpoints and endpoint associations, URL security profiles and profile groups.
It does not create or replace the network, subnets, router or NAT.

The child has no `egress_firewall` or `enabled` input. Its actual inputs are
defined in [variables.tf](variables.tf); root callers do not set them directly:

| Child input | Parent-supplied value |
|---|---|
| `name`, `project_id`, `network_id` | Environment name, project and existing VPC ID |
| `zones` (`set(string)`) | Root configured zones (or discovered regional zones) plus `egress_firewall.additional_workload_zones`; declare every workload zone |
| `internal_destination_cidrs` (`list(string)`) | Actual node, pod, service, PSA and active additional-subnet destination ranges |
| `classes` (`map(object({ policy_key, sources }))`) | `cluster` with node/pod CIDRs and the selected cluster policy, plus attached external groups with their CIDR and selected policy |
| `policies` | Root `egress_firewall.policies`, with `domain_allow` and `network_allow` maps for each policy |
| `platform_https_domains` (`set(string)`) | Built-in baseline union root additions; the child applies it only to the `cluster` class |

Child outputs in [outputs.tf](outputs.tf) are `readiness`, `effective_rules`,
`compiled_policy`, `enforcement_refs`, `capabilities`, `exclusions` and
`log_refs`. The root exposes these inside its `egress_firewall` output and
adds `enabled`, policy/baseline metadata, source `attachments`,
`configured_scope`, `nat_public_ips` and `web_egress_ips`. Those NAT addresses
and the separate `outbound_ips` and `additional_subnet_groups` outputs belong
to the root, not this child. `readiness.traffic_validated` and
`capabilities.live_validated` remain `false`: neither interface certifies live
traffic acceptance.

## Activate in a maintenance window

1. Verify authenticated Ryvn profile, organization, environment, installation
   and deployed module source. Confirm the selected release contains this
   implementation; do not infer availability from a version or channel name.
   Snapshot configuration, policy objects, workload/gateway/agent/collector
   health, actual ranges, zones, routes, NAT allocation ID and observed egress IP.
2. Inventory required domains and relevant Google APIs. Check the
   [provisioner permissions/API reference](../../permissions/README.md) and
   [custom role](../../permissions/provisioner-role.yaml), including Network Security
   and Certificate Authority API enablement/service-agent requirements. Do not
   assume an Owner-backed test establishes least-privilege readiness.
3. Review the full Ryvn Terraform task plan and required approvals. Reject
   unexpected cluster/subnet/range/NAT-address replacements or workload changes.
   Separate unrelated baseline reconciliation from activation. Preserve or
   explicitly pin the existing GKE zone selection without relocating node pools.
   No additional subnet groups are required for ordinary GKE use.
4. Ensure endpoint coverage for **every zone where workloads can run**, not only
   current nodes. Explicit `zones` cover GKE placement; when omitted, NGFW
   discovers all available zones in the region. Add external workload zones in
   `egress_firewall.additional_workload_zones` before placing workloads there.
   A regional subnet does not constrain VM zones.
5. During the approved window, submit the reviewed config through the normal
   Ryvn environment/task workflow, for example
   `ryvn update environment ENV --patch-file reviewed-egress.patch.yaml`.
   **Saving configuration triggers provisioning**; do not use that command as a
   preview. Follow normal task approval rules; do not bypass readiness guards.
6. Expect a deny-first interval. [The resource graph](main.tf)
   associates the final-deny policy **before** endpoint provisioning. Web
   inspection rules wait for **all** configured endpoints and associations to be
   `ACTIVE && !reconciling`. Wait for installation/task completion and capture
   endpoint/profile/policy readback. Pod `Ready` and endpoint `ACTIVE` alone
   are insufficient: run the fresh-traffic checks below before acceptance.

### Acceptance checks

- From ordinary **and host-network** pods in every active node zone, verify
  fresh allowed HTTPS/HTTP succeeds and denied domains fail. Cover wildcard
  children/nested names, apex/sibling negatives, exact tuples and wrong
  port/protocol/destination. Use controlled origins, request IDs, UTC times,
  source pod/node/zone/ports, receiver receipts and native firewall/URL/NAT logs.
  Keep controls to distinguish Kubernetes policy drops; timeout alone is inconclusive.
- Check DNS, metadata token retrieval, fresh OAuth/token exchange, Ryvn hub/agent
  heartbeat, uncached registry image pulls, collector token refresh and successful
  exports, existing gateways and workloads. A 401/403 proves only reachability;
  test authorized relevant Google API operations from protected sources too.
- Exercise actual SQL/Redis data, connector and management operations where
  present, plus application API dependencies. Mark absent services N/A.
- Run a non-mutating refresh/plan for a representative installation through the
  normal Ryvn task workflow. Hub-executor API access is not protected-pod evidence.
  Fresh-node bootstrap needs a separately reviewed safe additive-capacity check;
  do not drain/delete existing nodes to claim coverage.
- Verify NAT allocation identity and receiver-observed IP are unchanged.
  Retain read-back policy/config versions or hashes and evidence. Configured zones
  without active nodes are **untested traffic coverage**, even if endpoints are ready.

Restrict endpoint/association mutations and workload placement, alert on loss or
reconciliation failure, and use correlated per-zone allow/deny canaries. These
operational checks do not fix the protocol bypasses or create a fail-closed SLA.
Earlier isolated fresh-node and association-loss tests are not fresh validation
of an adopting environment; destructive failure injection is not an acceptance
step on a shared environment.

## Policy updates are eventual

Add/revoke/restore is not an atomic data-plane cutover. One bounded
existing-environment experiment observed these times on **new connections**:

| Change | Exact TCP tuple | HTTPS domain |
|---|---|---|
| Add | ~58 seconds | ~6 minutes 43 seconds |
| Revoke | ~83 seconds | ~3 minutes |
| Restore | ~52 seconds | ~6 minutes 31 seconds |

These are examples, not promises or an SLA. The per-phase observation window
was 15 minutes, not a supported propagation bound. Established-connection
samples were short-lived (under three seconds); they do not establish behavior
for long-lived flows spanning the entire propagation interval.

Use fresh connections and correlate origins/logs against the read-back policy
version for each phase. Restore temporary test changes. `ACTIVE` readback is
not traffic validation: endpoints can still have `reconciling = true` after a
policy update, temporarily failing follow-up Terraform previews. Wait for
`ACTIVE && !reconciling`; do not remove the guard to force an update through.

## Rollback and cost

If ordinary allowed traffic or platform availability fails to recover, make an
explicit security/availability decision to restore the reviewed prior config
with `egress_firewall.enabled: false` through Ryvn. **This disables NGFW filtering
and restores prior unrestricted public egress for the cluster at this module's
layer**; it is recovery, not a security pass. Existing Kubernetes controls remain
independent. Review the rollback plan, wait for convergence, repeat health/fresh
traffic checks and verify NAT identity. Do not simulate failure by deleting
endpoint/route associations. External attachments require special review below.

Google currently lists Enterprise endpoints at **$1.75 per endpoint-hour** plus
**$0.0193/GiB** inspected: three deployed zones are approximately **$5.25/hour**
before processing, credits/discounts, NAT, logging and other resources. Endpoint
cost applies even in a configured zone without an active node. Check the current
[Google pricing](https://cloud.google.com/firewall/pricing) before activation and
account for retained test fixtures separately.

## Optional external compute

`additional_subnet_groups` allocates external-compute subnets from
`additional_subnet_groups_cidr`; `egress_attachments` maps each active group to
a policy. Unattached groups have no Cloud NAT. Attached groups share root NAT
but receive only their selected policy, **not** the cluster platform baseline,
even if they share its policy key. Declare every external workload zone first.
These capabilities are optional and unnecessary for normal GKE use.

Applied allocation entries are append-only: do not reorder, resize, rename,
move or remove them. Remove an attachment before setting its group `retired: true`;
retirement removes the subnet but reserves its range. Disabling NGFW requires
removing attachments (the input contract rejects them while disabled), removing
their NAT coverage; review external-workload recovery separately.

The root NAT address has no destroy guard, but allocation-record guards remain.
With applied additional allocations, ordinary full Terraform destroy is blocked;
[destroy-environment.py](../../destroy-environment.py) is an explicit full-environment
destroy-only helper, **not** an activation, rollback or ordinary update tool.
GKE/DNS `deletion_protection` must still be disabled and applied before an
authorized teardown. Without allocation records no allocation override is
needed. Do not use teardown to validate this feature on a shared environment.

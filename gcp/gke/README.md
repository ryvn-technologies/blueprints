# GCP GKE Platform Module

Provisions the GCP half of a Ryvn environment: a VPC-native network with Cloud
NAT egress, a private GKE cluster with Workload Identity, Cloud DNS zones for
the environment's public and internal domains, and the service accounts the
in-cluster components impersonate.

This module is not meant to be consumed directly: it backs the `gcp-platform`
blueprint, and Ryvn applies it once per environment with inputs taken from the
environment's configuration. It is published for review — so you can see exactly
what gets created in your project before you hand one over. To create an
environment, see the [GCP environment
docs](https://ryvn.ai/docs/iac/environments/gcp); the variables below are the
knobs those docs expose.

## What's Included

- **Network**: a custom-mode VPC with one regional subnet, secondary ranges for
  pods and services, a reserved range for Private Service Access (so managed
  Cloud SQL and Memorystore instances can be peered in), a Cloud Router and a
  Cloud NAT with a static external IP, and firewall rules allowing traffic
  within the subnet, pod and service ranges. Public egress is unrestricted by
  this module by default; opt-in native Cloud NGFW adds domain filtering and
  exact TCP/UDP exceptions with the limitations below. Flow logs are on by default.
- **Cluster**: regional GKE with private nodes and a private control-plane
  endpoint, reached over the IAM-gated DNS-based endpoint, Workload Identity
  with `GKE_METADATA` on every node, and secure boot and integrity monitoring on
  the node pools. Kubernetes Secrets are encrypted with a Cloud KMS key (created
  here unless you bring your own or opt out). Control-plane and system logs go to
  Cloud Logging; managed Prometheus and the HTTP load balancing add-on are off —
  Ryvn ships its own collector and ingress. Dataplane V2 (with FQDN network
  policies) is opt-in via `datapath_provider`.
- **Node pools**: a `CriticalAddonsOnly`-tainted `system` pool and an
  `application` pool, both autoscaled with auto-repair and auto-upgrade. Pass `node_pools` to
  override sizes or add pools; defaults merge per key, and the system pool's
  taint cannot be removed.
- **IAM**: service accounts for the Ryvn agent, external-dns and cert-manager,
  each bound to its in-cluster Kubernetes service account through Workload
  Identity. The agent gets a custom role built from `default_permissions` in
  `gke.tf` — broad enough to manage instances, databases, buckets and networks,
  with no permission that reads object, row or log contents.
- **DNS**: a public and a private (VPC-scoped) Cloud DNS zone, with a CAA
  record restricting issuance to Let's Encrypt and Google Trust Services
  (`pki.goog`).

## Native managed egress (opt-in)

Omitting `egress_firewall`, or setting `enabled: false`, preserves legacy egress
and creates no NGFW resources. Upgrading to a release containing this feature
does **not** itself enable filtering. Review the entire Terraform upgrade plan:
other GKE settings, version reconciliation and IAM changes can still occur.

**First activation requires a maintenance window.** In a controlled
existing-environment validation, fresh allowed HTTPS and collector token refresh
were impaired during an approximately **55-minute activation task window**.
This was not a measured uninterrupted outage for every workload or a startup
SLA. Plan **at least an hour plus contingency**, with no guaranteed upper bound
or zero-downtime promise. Startup can be lengthy; API readiness and existing
pods being Ready do not prove fresh egress availability.

Ordinary HTTP Host / visible HTTPS SNI allow/deny, wildcards and exact tuples
worked at steady state in the tested active zones. This is not an HTTPS-only,
destination-ownership or universal fail-closed control. Read the
[egress-firewall module reference](modules/egress-firewall/README.md) for
configuration, activation, limits, checks, costs and rollback before adopting it.

## Key Variables

| Name | Description | Default |
|------|-------------|---------|
| `environment` | Environment name, used as a suffix throughout | required |
| `project_id` | GCP project to provision into | required |
| `region` | GCP region | required |
| `public_root_domain` / `internal_root_domain` | Domains for the Cloud DNS zones | required |
| `zones` | Zones for node pools; NGFW covers these zones, or discovers all available regional zones when omitted | `[]` |
| `subnet_cidr` | Primary subnet range | `"10.0.0.0/17"` |
| `pod_cidr` / `service_cidr` | Secondary ranges for pods and services | `"192.168.0.0/18"` / `"192.168.64.0/18"` |
| `node_pools` | Node pool overrides, merged with the defaults | `{}` |
| `node_pools_labels` | Extra labels per node pool | `{}` |
| `flow_logs` | VPC flow log configuration | enabled, 5s interval, 0.5 sampling |
| `create_cluster_kms_key` / `existing_cluster_kms_key_name` | Cloud KMS key for Secrets encryption: created here, or bring your own | `true` / `null` |
| `datapath_provider` | `ADVANCED_DATAPATH` for Dataplane V2; only applied at creation | `"DATAPATH_PROVIDER_UNSPECIFIED"` |
| `deletion_protection` | Block Terraform from destroying the cluster and DNS zones | `false` |
| `terraform_executor_policies` | Replace the Ryvn agent's default grants with `roles`, `permissions`, and/or conditional `bindings` | `{}` |
| `cluster_bootstrap_perms` | Grant the Terraform identity cluster admin for bootstrap | `false` |
| `skip_dns_provisioning` | Skip both Cloud DNS zones | `false` |
| `egress_firewall` | Native NGFW policy: `enabled`, deny-only `default_action`, `cluster_policy_key`, `policies` (`domain_allow` / `network_allow`), and `additional_workload_zones`. See the [parent configuration](modules/egress-firewall/README.md#parent-interface-environmentroot-configuration) | `{}` (`enabled = false`) |
| `platform_https_domains` | Additional exact HTTPS/443 platform hostnames for cluster sources; adds to the built-in baseline. The platform blueprint also derives hub/collector hosts | `[]` |
| `egress_firewall.additional_workload_zones` | Extra endpoint zones for external workloads in the same region; declare before placing workloads there | `[]` |
| `additional_subnet_groups` | Optional ordered, append-only external-compute subnet allocations; not required for ordinary GKE use | `[]` |
| `additional_subnet_groups_cidr` | Fixed allocation range for those groups; must not overlap existing ranges | `"10.0.192.0/19"` |
| `egress_attachments` | Optional map assigning an active group (`subnet_group_key`) to a policy (`policy_key`); requires NGFW enabled | `{}` |

The authoritative input types and validation are in [variables.tf](variables.tf).
Additional groups without attachments have VPC-local connectivity but no Cloud
NAT. Applied allocation entries cannot be removed, reordered, renamed, resized
or moved; retire a group to remove its subnet while reserving its range. See
[allocation and teardown caveats](modules/egress-firewall/README.md#optional-external-compute).

### Overriding the agent's permissions

Empty, the agent gets the default custom role plus a Cloud SQL role scoped to
instances tagged `ryvn-managed-<env>`. Supplying anything in
`terraform_executor_policies` replaces that whole set, the same way the AWS
module treats caller-supplied policy statements: only the grants listed are
bound, and the Cloud SQL scoping is dropped. The `ryvn-managed-<env>` tag
stays and the agent keeps attaching it, so an override can restate the scoping
with a binding conditioned on `resource.matchTag('<project>/ryvn-managed-<env>',
'true')`. `roles` binds predefined roles, `permissions` builds one custom role
(`ryvn_agent_role_<env>`), and `bindings` binds a predefined role or a custom
role built from `permissions` (created as `ryvn_agent_<env>_<name>`), optionally
under an IAM condition in the same shape `gcloud --condition` takes:

```hcl
terraform_executor_policies = {
  roles = ["roles/compute.admin"]
  bindings = [{
    name = "kms"
    role = "roles/cloudkms.admin"
    condition = {
      title      = "Ryvn key rings only"
      expression = "resource.name.startsWith(\"projects/my-project/locations/us-central1/keyRings/my-env-\")"
    }
  }]
}
```

Create permissions are authorized on the parent (the location for key rings,
the project for most resources), so a `resource.name` condition scopes the
operations on existing resources but not their creation.

## Outputs

`cluster_endpoint`, `cluster_endpoint_dns`, `cluster_ca_certificate`,
`cluster_name`, `cluster_region`, `cluster_secrets_encryption`,
`deletion_protection`, `vpc` (network, subnets and secondary ranges),
`outbound_ips`, `public_domain`, `internal_domain`, and the service account
emails and details for the Ryvn agent, external-dns and cert-manager.

`egress_firewall` publishes `enabled`, the cluster policy key, `platform_baseline`,
`effective_rules`, source `attachments`, `configured_scope`, `compiled_policy`,
`enforcement_refs`, `log_refs`, `readiness`, `capabilities` and `exclusions`.
Its enabled-mode `nat_public_ips` and `web_egress_ips` are the same existing root
NAT address as `outbound_ips`, not a second web address. Disabled-mode firewall
address lists are empty; use `outbound_ips` in either mode. Readiness is an
API-state check, with `traffic_validated = false`, not traffic acceptance.

`additional_subnet_groups` publishes active external subnet IDs, CIDRs, prefix
lengths and region independently of firewall membership. Only attached groups
appear in `egress_firewall.attachments`. See [egress_firewall.tf](egress_firewall.tf)
for the complete output contract.

## One-Way Decisions

The network name, subnet range and secondary ranges are fixed at creation; pod
and service ranges cannot be resized on a live cluster. The Private Service
Access range is consumed by peered managed services and cannot be reclaimed
while any of them exist. `datapath_provider` only takes effect at cluster
creation, and a KMS key ring cannot be deleted once created.

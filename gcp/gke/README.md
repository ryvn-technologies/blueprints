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
  within the subnet, pod and service ranges plus all egress. Flow logs are on by
  default.
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

## Key Variables

| Name | Description | Default |
|------|-------------|---------|
| `environment` | Environment name, used as a suffix throughout | required |
| `project_id` | GCP project to provision into | required |
| `region` | GCP region | required |
| `public_root_domain` / `internal_root_domain` | Domains for the Cloud DNS zones | required |
| `zones` | Zones for the cluster's node pools | `[]` (all zones in the region) |
| `subnet_cidr` | Primary subnet range | `"10.0.0.0/17"` |
| `pod_cidr` / `service_cidr` | Secondary ranges for pods and services | `"192.168.0.0/18"` / `"192.168.64.0/18"` |
| `node_pools` | Node pool overrides, merged with the defaults | `{}` |
| `node_pools_labels` | Extra labels per node pool | `{}` |
| `flow_logs` | VPC flow log configuration | enabled, 5s interval, 0.5 sampling |
| `create_cluster_kms_key` / `existing_cluster_kms_key_name` | Cloud KMS key for Secrets encryption: created here, or bring your own | `true` / `null` |
| `datapath_provider` | `ADVANCED_DATAPATH` for Dataplane V2; only applied at creation | `"DATAPATH_PROVIDER_UNSPECIFIED"` |
| `deletion_protection` | Block Terraform from destroying the cluster and DNS zones | `false` |
| `terraform_executor_policies` | Replace the Ryvn agent's permissions with roles *or* permissions | `{}` |
| `cluster_bootstrap_perms` | Grant the Terraform identity cluster admin for bootstrap | `false` |
| `skip_dns_provisioning` | Skip both Cloud DNS zones | `false` |

## Outputs

`cluster_endpoint`, `cluster_endpoint_dns`, `cluster_ca_certificate`,
`cluster_name`, `cluster_region`, `cluster_secrets_encryption`,
`deletion_protection`, `vpc` (network, subnets and secondary ranges),
`outbound_ips`, `public_domain`, `internal_domain`, and the service account
emails and details for the Ryvn agent, external-dns and cert-manager.

## One-Way Decisions

The network name, subnet range and secondary ranges are fixed at creation; pod
and service ranges cannot be resized on a live cluster. The Private Service
Access range is consumed by peered managed services and cannot be reclaimed
while any of them exist. `datapath_provider` only takes effect at cluster
creation, and a KMS key ring cannot be deleted once created.

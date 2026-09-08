# Provisioner permissions

IAM permissions for the identity that provisions, updates and deprovisions a Ryvn GKE
environment with this module. The counterpart for AWS lives in
`infra/aws-provision-karpenter/permissions/`.

| File | Purpose |
|------|---------|
| `provisioner-role.yaml` | Custom role for `ryvn-provisioner@<project>`, replacing `roles/owner` |

## Identity model

Ryvn never holds a key for the customer project. The control plane's AWS role
(`RyvnManagerRole`) federates through a Workload Identity pool the customer owns and
impersonates a per-project `ryvn-provisioner` service account. Two grants make that work:

1. **On the service account:** the grant that lets the hub act as the account, and
   nothing else in the project. For an AWS-rooted hub that is
   `roles/iam.workloadIdentityUser` for the pool's `principalSet` of `RyvnManagerRole`
   (`workloadIdentityUser` alone is sufficient for the impersonation-URL flow; do not add
   `serviceAccountTokenCreator` to work around fresh-project propagation delays). For a
   GCP-rooted hub it is `roles/iam.serviceAccountTokenCreator` for the hub's own service
   account, with no pool involved.
2. **On the project:** what the service account may do once impersonated:
   `provisioner-role.yaml` plus `roles/container.admin`.

`provisioner-role.yaml` is embedded into the orchestrator (`permissions.go`) and served by
`GET /v1/orgs/{orgId}/environments/provisioning/gcp-setup` together with the hub identity to
trust, so both provisioning screens render the `gcloud` commands from the API and a role
change ships with the next deploy. Setups made before this model granted `roles/owner` plus
a project-level `roles/iam.serviceAccountTokenCreator`; remove both once the new bindings
are in place. No code path uses the token-creator grant, which lets the provisioner mint
tokens for every service account in the project.

The runtime identity is different: after bootstrap the in-cluster agent runs as its own
`ryvn-agent-*` service account with the custom role defined in `gke.tf`
(`local.default_permissions`). That role is created *by* the provisioner and is out of
scope here.

## What the provisioner does

Everything the role has to cover, from the module's resource inventory plus the hub's
non-Terraform calls:

| Step | Resources | Permission group |
|------|-----------|------------------|
| Credential check (hub) | `compute.zones.list` on the project | compute reads |
| API enablement | `servicenetworking.googleapis.com` | `serviceusage.services.*`, `serviceusage.operations.get` (enable is a long-running operation on a project where the API is still off) |
| Network | VPC, subnet with secondary ranges and flow logs, two firewall rules | `compute.networks.*`, `compute.subnetworks.*`, `compute.firewalls.*`, `compute.networks.updatePolicy` |
| Egress | reserved external address, Cloud Router, Cloud NAT | `compute.addresses.*` including `setLabels` (provider 6.x sends the `goog-terraform-provisioned` label with the insert), `compute.routers.*` |
| Private Services Access | global internal range, service networking peering | `compute.globalAddresses.*` including `createInternal`/`deleteInternal` (the range is `address_type = INTERNAL`) and `setLabels`, `compute.networks.*Peering`, `servicenetworking.services.*` (`update_on_creation_fail = true` falls back to `UpdateConnection`, authorised by `addPeering`; there is no `updatePeering` permission) |
| Cluster | private regional GKE cluster, two node pools | `container.clusters.*`, `container.operations.*`, `compute.instanceGroupManagers.get` (provider reads each node pool's instance groups back after create), `iam.serviceAccounts.actAs` on the node service account |
| Identities | node, ryvn-agent, external-dns and cert-manager service accounts; Workload Identity bindings on each | `iam.serviceAccounts.*` |
| Roles and bindings | two custom roles, project bindings for the agent role, `roles/dns.admin` for external-dns and cert-manager, node service account roles, tag-conditioned Cloud SQL binding | `iam.roles.*`, `resourcemanager.projects.setIamPolicy` |
| Tags | tag key and value that scope the agent's Cloud SQL permissions | `resourcemanager.tagKeys.*`, `resourcemanager.tagValues.*` |
| DNS | public zone with CAA record, private zone bound to the VPC | `dns.managedZones.*`, `dns.resourceRecordSets.*`, `dns.changes.*`, `dns.networks.bindPrivateDNSZone` |
| Secrets encryption (`kms.tf`, #8055) | `cloudkms` API, GKE service identity, key ring + key via `terraform-google-modules/kms`, `cryptoKeyEncrypterDecrypter` grant to the service agent | `cloudkms.keyRings.create/get/list`, `cloudkms.cryptoKeys.create/get/list/update`, `cloudkms.cryptoKeys.getIamPolicy/setIamPolicy`; destroy with `prevent_destroy = false` runs `cryptoKeys.update` (drop rotation) plus `cryptoKeyVersions.list/destroy` since rings and keys themselves are undeletable. `google_project_service_identity` is authorised by `serviceusage.services.enable`, already present |
| Agent bootstrap (hub) | namespace, credentials secret, access RBAC, agent Helm release over the cluster API | `roles/container.admin` |
| Teardown | the same set in reverse | the delete permissions in each group |

The upstream module resources that our variables leave disabled (shadow and webhook
firewall rules, fleet registration, kube-dns and ip-masq config maps, registry grants)
need nothing extra.

## Why `roles/container.admin` is bound separately

GKE authorizes Kubernetes API calls made with a Google identity through IAM
`container.*` permissions. The hub installs the agent bundle over the cluster API:
namespace, secret, two ClusterRoles, ClusterRoleBinding, RoleBinding, ServiceAccount, and
the `ryvn-agent` Helm release (Deployment, Services, ServiceAccount, ClusterRole,
ClusterRoleBinding, Secret, ValidatingWebhookConfiguration). `roles/container.developer`
cannot create cluster-scoped RBAC or webhook configurations, so the predefined admin role
is the smallest predefined role that works. With the DNS-based control plane endpoint the
hub also needs `container.clusters.connect`, which every `container.*` role includes.

Once live validation has produced the exact list of `container.*` permissions the
bootstrap exercises, the predefined role can be swapped for those permissions inside the
custom role. Until then treat `roles/container.admin` as the required companion.

`gke.tf` also binds `roles/container.admin` to the executing identity itself (the hub
always sets `cluster_bootstrap_perms` since #8188; without it the module binds
`roles/container.developer`). With this role model that self-grant duplicates the binding
the setup commands make, and `terraform destroy` removes it again, so after a deprovision the
service account keeps only the custom role until the next apply re-adds the admin binding.
Removing the self-grant so the provisioner never writes its own project bindings is a
follow-up.

## IAM-write permissions and how to bound them

Six permissions let the provisioner change who can do what in the project:

- `resourcemanager.projects.setIamPolicy`
- `iam.roles.create`, `iam.roles.update`, `iam.roles.delete`, `iam.roles.undelete`
- `iam.serviceAccounts.setIamPolicy`

They are required because the module creates the agent's custom roles and every
project-level binding listed above. GCP has no per-binding equivalent of an AWS
permissions boundary, so a customer that must limit them has three levers:

1. **Dedicated project per environment.** The role is project-scoped; nothing outside the
   project is reachable. This is the precondition to insist on.
2. **Custom organization policy on IAM allow policies.** Restrict the roles the provisioner
   may grant to the ones the module actually binds: `roles/container.developer`,
   `roles/container.admin`, `roles/dns.admin`, `roles/container.defaultNodeServiceAccount`,
   `roles/monitoring.metricWriter`, `roles/stackdriver.resourceMetadata.writer`,
   `roles/iam.workloadIdentityUser`, and the project's `ryvn_agent_role_*` and
   `ryvn_agent_cloudsql_role_*` custom roles. Confirm availability of custom constraints on
   `iam.googleapis.com/AllowPolicy` with the customer's organization admins.
3. **Pre-provisioned IAM (strict mode, not yet supported by the module).** The customer
   creates the four service accounts, both custom roles, the tag key and value, and every
   binding themselves, and the provisioner keeps only `iam.serviceAccounts.get`, `list`,
   `getIamPolicy` and `actAs`. This drops the six permissions above plus
   `iam.serviceAccounts.create`, `delete`, `update` and the `resourcemanager.tag*` group. It
   needs module inputs to accept pre-created identities instead of creating them
   (`create_service_account = false` plus a way to skip the agent, external-dns and
   cert-manager resources), which is a separate change.

## Dedicated hub: second hop into end-customer accounts

When this module hosts a customer's own Ryvn control plane (dedicated BYOC hub, e.g.
`hs-ryvn-deploy`), there are two provisioning hops with different identities:

| Hop | Caller | Target | Identity |
|-----|--------|--------|----------|
| 1 | Ryvn SaaS (`RyvnManagerRole`, AWS) | hub project | AWS -> WIF -> `ryvn-provisioner` (this document) |
| 2 | dedicated hub (GKE pod in the hub project) | end-customer GCP project / AWS account / Azure subscription | hub's own Google service account via Workload Identity |

Hop 2 uses none of hop 1's credentials. The hub pod runs as a Google service account
(call it `ryvn-hub@<hub-project>`, bound to the orchestrator's Kubernetes ServiceAccount
with `roles/iam.workloadIdentityUser`; this module does not create it yet). That account
is the principal every end-customer account has to trust. What each target needs:

**End-customer GCP project.** Same resources as hop 1, so the same `provisioner-role.yaml`
+ `roles/container.admin` bound to a per-project `ryvn-provisioner` service account. The
trust grant differs: instead of a WIF `principalSet`, bind the hub's Google identity
directly on the target account:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  ryvn-provisioner@TARGET_PROJECT.iam.gserviceaccount.com \
  --project=TARGET_PROJECT \
  --role=roles/iam.serviceAccountTokenCreator \
  --member=serviceAccount:ryvn-hub@HUB_PROJECT.iam.gserviceaccount.com
```

`workloadIdentityUser` is the wrong role here (it is for external federated principals);
`serviceAccountTokenCreator` scoped to the one target account is the only grant needed,
and it does not need to be project-wide. Organization policies
`iam.disableCrossProjectServiceAccountUsage` and `iam.allowedPolicyMemberDomains` must
permit the hub project's identity in the target project. The APIs listed under
"Customer-side one-time setup" must be enabled in the target project as well.

**End-customer AWS account.** The standard `RyvnAccessRole` stack
(`infra/perms/aws/cloudformation-access-role.json`) covers the resource permissions, but
its trust policy only accepts an AWS principal. A Google-hosted hub authenticates with a
Google-signed OIDC token, so the role needs an additional trust statement:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "accounts.google.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "accounts.google.com:sub": "<unique ID of ryvn-hub@HUB_PROJECT>" }
  }
}
```

Guard on `sub` (the service account's numeric unique ID), not `aud`. On the hub side the
pod must be able to mint an ID token for itself: `roles/iam.serviceAccountOpenIdTokenCreator`
on `ryvn-hub` for `ryvn-hub`, or use the GKE metadata server identity endpoint.

**End-customer Azure subscription.** The `ryvn-aks-provision` custom role from the guided
setup covers the resource permissions (including the `Microsoft.Authorization/roleDefinitions|roleAssignments/write`
the AKS module needs). Replace the `az ad sp create-for-rbac` client secret with a
user-assigned managed identity plus a federated identity credential trusting the hub:
issuer `https://accounts.google.com`, subject `<unique ID of ryvn-hub@HUB_PROJECT>`,
audience `api://AzureADTokenExchange`. The identity is then assigned `ryvn-aks-provision`
at the target scope. No Entra application registration is required.

**Ryvn-owned dependencies the hub still reaches.** Terraform state (S3), the environment
KMS master key and Route53 domain delegation stay in Ryvn's AWS account. The dedicated hub
needs an AWS role in Ryvn's account trusting `accounts.google.com` with the same `sub`
condition, granting only the state bucket prefix, the KMS key and the delegation zone.

**Code status.** The hub currently authenticates to targets from an AWS-rooted identity
only (`pkg/terraform/identity.go`, `internal/roleassumption/`): GCP targets via pasted
AWS external-account credentials, AWS targets via ambient IRSA, Azure targets via client
secret. The Google-rooted sources above are the ENG-1908 outbound work and are not
implemented; hop 2 cannot run until they land. Everything in this section that is IAM can
be provisioned ahead of that.

## Customer-side one-time setup

The customer runs the setup script that the Ryvn API renders for their project
(`GET /v1/orgs/{orgId}/environments/provisioning/gcp-setup?projectId=…`, shown in the dashboard
and printed by `ryvn get gcp-setup-script`). It is rendered from `internal/provision/gcp_setup.go`
with this directory's role and API lists. Whoever runs it needs, in the target project:
`roles/serviceusage.serviceUsageAdmin` (enable APIs), `roles/iam.serviceAccountAdmin`
(create `ryvn-provisioner` and bind on it), `roles/iam.roleAdmin` (create this custom role),
`roles/resourcemanager.projectIamAdmin` (bind it), and, on AWS-rooted hubs,
`roles/iam.workloadIdentityPoolAdmin` (the pool and provider are created in the target project).

The script first enables the APIs in `RequiredAPIs` (`permissions.go`): `iam`, `iamcredentials`,
`sts`, `cloudresourcemanager`, `compute`, `container`, `servicenetworking`, `dns`, and
`cloudkms`. It is safe to re-run; each step updates what already exists. Failed Google requests
stop setup (`set -euo pipefail`) and print Google's original error.

`sqladmin` is not in that list: enable it yourself if the Cloud SQL blueprint will be used
(always, for a dedicated hub: its Postgres comes from `infra/ryvn-postgres/gcp`), since
Terraform no longer manages that API. Projects created with project-factory style
`activate_apis` lists commonly omit `servicenetworking`, `dns` and `sqladmin`; the
provisioner can enable them itself only if no organization policy blocks
`serviceusage.services.enable`.

## Live validation (2026-09-03)

Run in scratch project `byoc-test-507301` as `ryvn-provisioner-test@`, bound to this
role and `roles/container.admin` only (no `roles/owner`; the harness impersonated the
account through an SA-level `serviceAccountTokenCreator` grant held by a separate admin
identity). Data Access audit logs (`ADMIN_READ`, `DATA_READ`, `DATA_WRITE`, all services)
were enabled before the first call. Sequence, all with `enable_private_endpoint = true`
and `datapath_provider = ADVANCED_DATAPATH`, on the module with `kms.tf` (#8055) merged in:

1. `terraform apply` (46 resources).
2. Bootstrap over the DNS control-plane endpoint: namespace, ServiceAccount with the
   Workload Identity annotation, cluster-admin ClusterRoleBinding, Secret, Helm release.
3. `terraform plan` + `apply` again (re-apply).
4. `terraform destroy` (46 resources, clean).

Audit logs for the principal were then reduced to `(permission, methodName)` pairs and
diffed against the role:

```bash
gcloud logging read \
  'protoPayload.authenticationInfo.principalEmail="ryvn-provisioner-test@PROJECT.iam.gserviceaccount.com"' \
  --project=PROJECT --freshness=1d --format=json --limit=5000 \
  | jq -r '.[].protoPayload | .methodName as $m | .authorizationInfo[]? | [.permission, $m, (.granted|tostring)] | @tsv' \
  | sort | uniq -c
```

### Denials and corrections

| Finding | Effect | Change |
|---------|--------|--------|
| `servicenetworking.services.updatePeering` is not a permission | `gcloud iam roles create` rejects the file (`INVALID_ARGUMENT`); `queryTestablePermissions` lists only `addPeering`, `deleteConnection`, `get`, `updateConsumerConfig` | removed |
| `compute.addresses.setLabels` denied on `v1.compute.addresses.insert` (`nat-ip-<env>`) | apply fails at the NAT address; provider 6.x adds the `goog-terraform-provisioned` label to the insert body | added |
| `compute.globalAddresses.setLabels` denied on `v1.compute.globalAddresses.insert` (`private-services-<env>`) | apply fails at the PSA range, same cause | added |
| `compute.instanceGroupManagers.get` denied on `beta.compute.instanceGroupManagers.get` after `CreateCluster` | cluster is created but the post-create read fails, Terraform taints it and the next apply replaces the cluster | added |

No other call was denied across apply, bootstrap, re-apply and destroy.

### Permissions exercised, by audit-logged method

Phases: A = apply, B = bootstrap, R = re-apply, D = destroy.

| Permission | Method(s) in audit log | Phase | What it did |
|------------|------------------------|-------|-------------|
| `resourcemanager.projects.get` | `GetProject` | A R D | provider reads the project for every `google_project_*` resource |
| `resourcemanager.projects.getIamPolicy` | `cloudresourcemanager GetIamPolicy` | A R D | read-modify-write for each `google_project_iam_member` |
| `resourcemanager.projects.setIamPolicy` | `cloudresourcemanager SetIamPolicy` | A D | node SA roles, agent role bindings, `dns.admin` for external-dns/cert-manager, `container.developer` self-grant, tag-conditioned Cloud SQL binding |
| `serviceusage.services.enable` | `ServiceUsage.EnableService`, `Operations.GetOperation` | A | `servicenetworking` and `cloudkms` API enable, `google_project_service_identity.container` |
| `serviceusage.services.get` | `Operations.GetOperation` | A | reading the enable operation result |
| `serviceusage.operations.get` | `Operations.GetOperation` | A | polling the enable long-running operation |
| `compute.zones.list` | `beta.compute.zones.list` | A R D | `google_compute_zones` data source picks node zones (also the hub's credential check) |
| `compute.globalOperations.get` | `v1/beta.compute.globalOperations.get` | A D | network, firewall, global address operations |
| `compute.regionOperations.get` | `v1.compute.regionOperations.get` | A D | subnet, router, NAT, regional address operations |
| `compute.networks.create` / `get` / `delete` | `beta.compute.networks.insert` / `get` / `delete` | A R D | `gke-network-<env>` VPC |
| `compute.networks.updatePolicy` | `firewalls.insert/delete`, `routers.insert/patch`, `subnetworks.insert` | A R D | checked on the VPC for every attached firewall, router and subnet write |
| `compute.networks.use` | `v1.compute.globalAddresses.insert` | A | the PSA range attaches to the VPC |
| `compute.subnetworks.create` / `get` / `delete` | `v1.compute.subnetworks.insert` / `get` / `delete` | A R D | `gke-subnet-<env>` with secondary ranges |
| `compute.firewalls.create` / `get` / `delete` | `v1.compute.firewalls.insert` / `get` / `delete` | A R D | `allow-internal-<env>`, `allow-egress-<env>` |
| `compute.addresses.create` / `get` / `delete` | `v1.compute.addresses.insert` / `get` / `delete` | A R D | `nat-ip-<env>` |
| `compute.addresses.setLabels` | `v1.compute.addresses.insert`, `v1.compute.addresses.setLabels` | A | attribution label on the NAT address |
| `compute.routers.create` / `get` / `update` / `delete` | `v1.compute.routers.insert` / `get` / `patch` / `delete` | A R D | `nat-router-<env>`; `google_compute_router_nat` is a `routers.patch` |
| `compute.globalAddresses.createInternal` / `get` / `deleteInternal` | `v1.compute.globalAddresses.insert` / `get` / `delete` | A R D | `private-services-<env>` (`INTERNAL`, `VPC_PEERING`) |
| `compute.globalAddresses.setLabels` | `v1.compute.globalAddresses.insert`, `v1.compute.globalAddresses.setLabels` | A | attribution label on the PSA range |
| `servicenetworking.services.addPeering` | `ServicePeeringManager.CreateConnection`, `Operations.GetOperation` | A | PSA connection |
| `servicenetworking.services.get` | `ServicePeeringManager.ListConnections` | A R D | reading the connection back |
| `servicenetworking.services.deleteConnection` | `ServicePeeringManager.DeleteConnection`, `Operations.GetOperation` | D | PSA connection teardown |
| `servicenetworking.operations.get` | `Operations.GetOperation` | A D | polling connection operations |
| `container.clusters.create` | `v1beta1.ClusterManager.CreateCluster` | A | `ryvn-gke-<env>` (private endpoint, Dataplane V2, CMEK) |
| `container.clusters.get` | `GetCluster` (v1 + v1beta1), `GetNodePool`, `ListNodePools` | A B R D | reads of cluster and node pools; `gcloud container clusters get-credentials` |
| `container.clusters.list` | `v1.ClusterManager.GetServerConfig` | A R D | `google_container_engine_versions` data source |
| `container.clusters.update` | `CreateNodePool`, `DeleteNodePool`, `UpdateCluster` | A R D | `system` and `application` node pools; in-place cluster update on re-apply |
| `container.clusters.delete` | `v1beta1.ClusterManager.DeleteCluster` | D | cluster teardown (also the replacement after the tainted first create) |
| `container.operations.get` | `v1beta1.ClusterManager.GetOperation` | A R D | polling every cluster/node pool operation |
| `compute.instanceGroupManagers.get` | `beta.compute.instanceGroupManagers.get` | A R D | provider populates `instance_group_urls` / `managed_instance_group_urls` |
| `iam.serviceAccounts.create` / `get` / `delete` | `CreateServiceAccount` / `GetServiceAccount` / `DeleteServiceAccount` | A R D | node, ryvn-agent, external-dns, cert-manager SAs |
| `iam.serviceAccounts.list` | `GetServiceAccount` | A | checked alongside `get` on the first read after create |
| `iam.serviceAccounts.getIamPolicy` / `setIamPolicy` | `GetIAMPolicy` / `SetIAMPolicy` | A R D | `roles/iam.workloadIdentityUser` on each SA for its KSA |
| `iam.serviceAccounts.actAs` | `iam.serviceAccounts.actAs` | A | node service account attached to cluster and node pools |
| `iam.roles.create` / `get` / `delete` | `CreateRole` / `GetRole` / `DeleteRole` | A R D | `ryvn_agent_role_*`, `ryvn_agent_cloudsql_role_*` |
| `resourcemanager.tagKeys.create` / `get` / `delete` | `TagKeys.CreateTagKey` / `GetTagKey` / `DeleteTagKey` | A R D | `ryvn-managed` tag key |
| `resourcemanager.tagValues.create` / `get` / `delete` | `TagValues.CreateTagValue` / `GetTagValue` / `DeleteTagValue` | A R D | tag value that scopes the Cloud SQL role |
| `dns.managedZones.create` / `get` / `delete` | `dns.managedZones.create` / `get` / `delete` | A R D | public and internal zones |
| `dns.resourceRecordSets.create` | `dns.changes.create` | A | CAA record |
| `dns.resourceRecordSets.delete` | `dns.changes.create` | D | `force_destroy` clears records before zone delete |
| `dns.resourceRecordSets.list` | `dns.resourceRecordSets.list` | A R D | record reads |
| `dns.changes.get` | `dns.changes.get` | A R D | polling the record change |
| `cloudkms.keyRings.create` / `get` | `CreateKeyRing` / `GetKeyRing` | A R D | `ryvn-gke-<env>-<hex>` ring |
| `cloudkms.cryptoKeys.create` / `get` | `CreateCryptoKey` / `GetCryptoKey` | A R D | `ryvn-gke-<env>-secrets` key |
| `cloudkms.cryptoKeys.update` | `UpdateCryptoKey` | D | provider clears the rotation schedule before dropping the key from state |
| `cloudkms.cryptoKeys.getIamPolicy` / `setIamPolicy` | `GetIamPolicy` / `SetIamPolicy` | A R D | `cryptoKeyEncrypterDecrypter` for the GKE service agent |
| `cloudkms.cryptoKeyVersions.list` / `destroy` | `ListCryptoKeyVersions` / `DestroyCryptoKeyVersion` | D | schedules every key version for destruction (`prevent_destroy = false`) |

Bootstrap calls (`io.k8s.*` create/get/list/patch on namespaces, serviceaccounts, secrets,
clusterrolebindings, deployments, services, networkpolicies, poddisruptionbudgets) were
authorised by `roles/container.admin`; GKE logs them without an IAM permission name, so
the exact `container.*` subset still cannot be derived from logs.

### Permissions in the role that were not exercised

Not observed in this run does not mean unnecessary: the run had no drift, so no in-place
update of a network, firewall, subnet, DNS zone, tag, role or service account happened,
and the provider reads resources by name rather than listing them. Kept, grouped by why:

| Group | Permissions | Why kept |
|-------|-------------|----------|
| In-place updates on re-apply with changed inputs | `compute.networks.update`, `compute.firewalls.update`, `compute.subnetworks.update`, `compute.subnetworks.setPrivateIpGoogleAccess`, `dns.managedZones.update`, `dns.resourceRecordSets.update`, `iam.roles.update`, `iam.roles.undelete`, `iam.serviceAccounts.update`, `resourcemanager.tagKeys.update`, `resourcemanager.tagValues.update` | variable changes (flow logs, firewall sources, agent role permission list shipped in module updates, descriptions) patch these in place; `iam.roles.undelete` covers re-creating an environment name within the 7-day role tombstone |
| List / read variants | `compute.projects.get`, `compute.regions.get/list`, `compute.zones.get`, `compute.zoneOperations.get`, `compute.networks.list`, `compute.subnetworks.list`, `compute.firewalls.list`, `compute.addresses.list`, `compute.routers.list`, `compute.globalAddresses.list`, `container.operations.list`, `dns.managedZones.list`, `dns.changes.list`, `dns.managedZoneOperations.get`, `dns.resourceRecordSets.get`, `iam.roles.list`, `resourcemanager.tagKeys.list`, `resourcemanager.tagValues.list`, `serviceusage.services.list`, `cloudkms.keyRings.list`, `cloudkms.cryptoKeys.list` | `terraform import`, `gcloud` inspection during support, and provider code paths for existing-resource detection use them; candidates for removal once a strict mode exists |
| Checked without a log entry, or on a path this run did not take | `dns.networks.bindPrivateDNSZone` (private zone was created and bound to the VPC; the DNS API did not log the permission), `compute.networks.addPeering` / `removePeering` / `updatePeering` (Service Networking creates the consumer side of the peering as the producer service agent), `compute.globalAddresses.create` / `delete` / `use`, `compute.addresses.use`, `compute.subnetworks.use` (the internal range only exercised the `*Internal` variants; NAT uses `routers.patch`) | kept defensively; a second run with a customer-supplied external PSA range or an existing peering would exercise the non-internal variants |

### Other findings from the run

- Re-apply is not idempotent with `kms.tf`: the cluster reports
  `database_encryption.state = ALL_OBJECTS_ENCRYPTION_ENABLED` while the module sets
  `ENCRYPTED`, so every plan shows an in-place update and the resulting `UpdateCluster`
  failed with `DeployPatch failed` (`CURRENT_STATE_ALL_OBJECTS_ENCRYPTION_ERROR`). Not a
  permission issue; needs a fix in #8055 (accept the new state value or ignore changes).
- The first apply's tainted cluster was replaced on the second apply; with the
  `instanceGroupManagers.get` permission present this does not recur.
- Destroy completed in one pass, including PSA connection, KMS key versions and the DNS
  zones with records.

Two destroy failures are ordering problems, not missing permissions, and the role
deliberately does not paper over them: `tagValues.delete` is rejected while agent-created
Cloud SQL instances still carry the tag binding, and the Private Services Access connection
cannot be removed while Cloud SQL or Memorystore instances still use the peered range. The
agent's resources have to be torn down before the platform.

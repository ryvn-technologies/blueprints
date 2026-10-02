# Azure egress: customer setup and operations

Use this with the [feature reference](README.md). The public inputs belong to the
Azure platform root/environment configuration. This is the operational procedure;
fixture IDs and historical retries belong in the internal validation report.

## Prepare the environment

1. Choose a root-owned VNet (`/21` or larger), region/zones with Firewall and AKS
   capacity, and Standard unless Premium is specifically required. Verify vCPU and
   public-IP quotas; quota is not allocation-capacity proof. Account for firewall
   and log costs. The current single-IP implementation needs a separate production
   SNAT-capacity review.
2. Inventory the customer's external APIs and exact/wildcard domains. Separate
   cluster rules from additional compute policies. Review every CIDR/port pinhole
   as a hostname-inspection bypass. Confirm shared-registry baseline breadth.
3. Review the rendered `platform_https_domains` from hub context, including the
   actual collector endpoints. Direct module callers supply these themselves.
4. Decide the ingress path. A public LoadBalancer with a default route through
   the firewall is not automatically supported; account for asymmetric replies.
5. Publish/register the Terraform module and updated Azure platform blueprint,
   and deploy an orchestrator release containing the embedded Azure role JSON.
   Update the subscription's existing role before activation; the running hub does
   not pick up permission changes from a Terraform merge. A role-only update avoids
   rotating the secret-backed provisioner's credentials; full setup reruns rotate
   that password. Check Network/Insights/OperationalInsights provider registration.
   See the [permissions guide](../../permissions/README.md). Preserve
   backend/state recovery access and an Azure management-plane break-glass identity
   independent of cluster connectivity. Choose an owner for policy review and
   drift/log monitoring.

## Plan and apply

For a new environment, set `egress_firewall.enabled = true` on the first apply.
Declare the cluster policy even when its customer maps are empty. Add optional
subnet groups and attachments using the reference example. Review the plan's
source ranges, exact platform hosts, service-endpoint removal, routes, public IPs
and log resources. The normal graph builds enforcement before AKS and adds the
API exception after the API FQDN exists; no second enablement apply is required.
The Ryvn blueprint controls Cilium through `enableManagedCilium`; direct root
callers use `ebpf_data_plane`. Latest direct-cloud acceptance did not test Cilium.

For an existing environment, first run a **firewall-disabled upgrade plan** with
its real state. Review all resource changes against the installed release; disabled does not mean
an upgrade can have no other diffs. Then plan activation
separately. Record current routes, service-endpoint-dependent ACLs, egress IPs and
rollback configuration. Approve a maintenance window for route/outbound-IP changes
and possible AKS changes shown by that environment's plan. Disabling subnet default outbound does not immediately remove implicit IPs
from existing NICs: Azure requires stop/deallocate for existing VMs. For AKS use
supported node replacement/maintenance, and verify NIC/default-outbound state and
absence of alternate egress before claiming fallback protection after route loss.
Do not manually stop managed VMSS instances as a substitute for an AKS migration
plan. [Azure behavior](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access).
Do not equate a no-op plan on the fresh fixture with an existing-environment
upgrade test.

After successful root apply, review `outbound_ips` and `egress_firewall` outputs,
then apply separate-state consumers using `attachments.<name>.subnet_id`. Update
destination IP allowlists as part of the cutover. Do not bootstrap applications
before the full root apply (including the post-cluster API rule) completes.

## Acceptance before customer activation

Run these on both a new and an existing Ryvn test environment after merge:

- Use the actual scoped provisioner identity (not admin) for create, update and
  teardown permission checks.
- Cilium/cluster health, API access from application namespaces, fresh image pulls
  and node replacement; full managed add-ons and certificate issuance.
- Agent authentication/reconnect, Connect and telemetry to the actual managing hub.
- Repeated allowed HTTP/80 and HTTPS/443 and forbidden destinations from ordinary
  pods, hostNetwork and attached VMs. Verify exact/wildcard boundaries, network
  pinholes and external-class denial of cluster-only platform hosts.
- Matching native allow/deny logs. Use the KQL in `egress_firewall.log_refs`, wait
  for an observed canary, and correlate timestamps and source/destination.
- Intended ingress and return traffic; egress tests alone do not establish ingress.
- Attachment reassignment and detachment, existing service/private endpoint access,
  expected outbound IPs and a final no-op Terraform plan.

Record missing coverage explicitly. The current regional fixture can be reused
for targeted follow-ups; customer acceptance requires the intended Ryvn topology.

## Failed apply or unhealthy firewall

Capture the resource ID, UTC window, current provisioning state, Activity Log
nested error, request/correlation ID and actual async-operation result. An HTTP
200/202 accepting an update does not establish successful completion. Do not
interpret a generic `InternalServerError` as a capacity diagnosis.

Check dependent subnet/policy states and Service Health. Terraform now sequences
its subnet writes before firewall operations; concurrent out-of-band writes can
still race. After dependencies settle, a reviewed unchanged retry may recover a
transient failure. Do not loop retries or edit state to force a tier transition.
If Azure created a resource but Terraform did not record it, review ownership and
import before retrying creation. Back up state and retain failing resources for
support diagnosis when requested.

If one region remains blocked, an isolated test fixture in another supported
region can unblock validation. Use a new resource group and state; never change
`location` in the retained fixture to achieve that. A successful alternate region
does not prove the original cause.

## Retirement and full deletion

For ordinary group retirement:

1. Remove all consumers (VMs/NICs/private endpoint attachments) from that group.
2. Remove its `egress_attachments` entry and apply; verify the default route is
   `None` and that no alternate egress exists.
3. Set `retired = true` and apply. Keep that entry forever. Its subnet is removed;
   its address allocation is reserved. Removal/rename/reorder/resize is rejected.

For **full environment deletion**, archive required logs and state; destroy all
separate-state consumers first. Detach groups and verify their drop routes. Group
allocation records have `prevent_destroy`, so a normal destroy plan is blocked.
After verifying the exact backend/workspace and full-deletion intent, explicitly
release only those records for each group (including retired groups):

```bash
terraform state list
# These addresses are for the standalone root. A composed module adds its prefix.
terraform state rm 'terraform_data.additional_subnet_ledger["api_clients"]'
terraform state rm 'terraform_data.additional_subnet_geometry["api_clients"]'
terraform plan -destroy -out=destroy.tfplan
# Review the complete destroy plan, then apply it through the normal workflow.
```

This is a deliberate full-deletion escape hatch, not a way to reuse/rename ranges.
Do not run an ordinary apply between release and the reviewed destroy: it would
recreate the records. Keep state/backend resources until deletion is verified.
Check Azure resource groups, AKS-managed resources, firewall/public IP/workspace
inventory and empty managed state. Deleting a state record alone deletes no Azure
resource. The automatic Ryvn deletion path needs to account for this manual step
when additional groups exist.

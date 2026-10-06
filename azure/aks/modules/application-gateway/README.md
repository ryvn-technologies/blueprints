# Azure Application Gateway TCP ingress

Opt-in `Standard_v2` public TCP 80/443 forwards to the existing external Istio gateway. Istio owns TLS, certificates, SNI/Host and routes. Azure Firewall remains default-deny egress. The internal gateway and Private Link frontend remain independent.

## Planned address, then runtime readiness

```text
Azure platform Terraform: application_gateway_enabled=true
  -> dedicated ingress-lb-subnet, fixed infrastructure slot 5
  -> application_gateway_network v2: backend{subnet_id,subnet_name,subnet_cidr,private_ip}
       +-> ryvn-gateway Helm values -> ryvn-agent -> Service -> AKS internal LB
       +-> platform child module -> AppGW backend pool (same root/state)
```

Both consumers use the same `cidrhost(subnet_cidr, 4)` IPv4. Terraform can configure AppGW before the Service exists. Infrastructure creation never waits on Kubernetes or backend health. There is no Kubernetes provider, Service/ConfigMap discovery, Helm output dependency or UID/address handoff.

The Azure AKS root invokes this module and owns its state. Enable `application_gateway_enabled: true` in the Azure environment config and provision the platform first. Its existing blueprint forwards config to Terraform and publishes outputs into environment state. On Azure, an enabled external gateway automatically consumes `application_gateway_network.enabled` and deploys its additional private Service. Missing/old output or `enabled: false` leaves gateway configuration unchanged. There is no separate AppGW Service, installation or gateway enable switch.

`application_gateway_enabled` and `egress_firewall.enabled` are independent and default false. For supported public ingress with managed egress filtering, operators explicitly enable both and keep `enableExternalGateway` enabled. Private-only environments can leave AppGW off. Terraform neither discovers gateway enablement nor couples the flags. Disabled AppGW creates no new subnet, IP or DNS. Existing infrastructure/node subnet names, CIDRs and Terraform addresses do not shift: slots 0/1 remain AppGW/Private Link, 2 service pool, 3 Postgres and 4 Firewall. Slot 5 is a separate additive resource, outside the service-pool and additional-subnet region. Both overlay and flat modes use the existing geometry. With current geometry, /16 and /19 produce /24 infrastructure subnets; /20–/24 are rejected because the unchanged AppGW subnet is too small or slot 5 does not fit. No network is automatically re-carved. Existing-VNet operators must confirm the reserved range is free before enabling.

## Platform API

| Azure environment config | Default | Purpose |
| --- | --- | --- |
| `application_gateway_enabled` | `false` | AppGW resources and dedicated ingress-LB subnet/IP |
| `application_gateway_name` | `null` → `appgw-<environment_name>` | Stable AppGW name; PIP/NSG use `pip-`/`nsg-` prefixes |
| `application_gateway_public_dns` | `null` | `{record_names, ttl=30}` in the platform public zone |
| `application_gateway_activation` | `{}`; all fields false | `publish_dns`, `dns_owner_released`, `backend_healthy`, `tls_routes_ready`, `firewall_self_calls_ready` |

The version 2 `application_gateway_network` output contains `enabled`, subnet references, the planned `backend` descriptor and nullable `gateway{id,public_ip,public_ip_id,backend_ip,public_dns_published,...}`. These fields describe configured resources, not health. The child receives root resource/local references directly; subnet reads depend on subnet creation. It inherits the root AzureRM provider, already pinned to 4.81.0; no platform provider upgrade is required.

The frontend subnet has no implicit outbound access or route-table association and must not host node pools. Existing AKS VNet-scoped Network Contributor covers subnet read/join/network operations; no new RBAC or controller is introduced.

### Address lifecycle

The planned IP is an address contract, not an Azure reservation resource. AKS claims it when reconciling the Helm Service. Deleting the Service releases it; recreation requests the same annotation IP. Keep unrelated workloads from claiming it. Recovery still depends on AKS reconciliation and health checks. Do not use a dummy NIC or edit generated LB rules.

The chart requires the subnet name and private IPv4 and selects existing external gateway pods. It retains `Local`, TCP 80/443, AppGW subnet source restrictions, `/healthz`, ExternalDNS exclusion and the supported ten-minute idle-timeout annotation. It uses Azure's IPv4 annotation rather than deprecated `spec.loadBalancerIP`, and rejects internal attachment, PROXY and trusted forwarding headers.

## Ownership and activation

| Resource | Owner |
| --- | --- |
| Dedicated AppGW and ingress-LB subnets / planned IP contract | platform Terraform |
| AppGW, public IP, NSG/association, selected public A records | platform Terraform root/state, through this child module |
| Additional private Service | existing external `ryvn-gateway` Helm installation, deployed by `ryvn-agent` |
| Azure internal LB frontend, generated probes/rules/timeouts | AKS native controller |
| TLS, certificate Secrets, SNI/Host/routes | existing Istio, cert-manager and applications |
| Public self-call allows / default-deny egress | Azure Firewall policy |
| Internal frontend, PLS/PE, private DNS/NAT | existing Private Service owners |

Terraform only writes Azure objects; it never creates/patches/adopts Kubernetes or uses Helm/kubectl/local-exec wrappers. Existing Azure objects need reviewed import/state transfer; foreign NSGs and route-table associations fail. The dedicated backend subnet must match the contract and share the AppGW VNet.

DNS is off by default. After actual backend health, TLS/routes and Firewall self-call verification, explicitly set all `application_gateway_activation` fields true and configure exact `application_gateway_public_dns.record_names`. A later reviewed platform apply publishes DNS; the initial apply has no health wait. These are operator attestations, not inferred readiness. One authoritative writer owns the selected public records. An exclusion annotation alone does not prove ExternalDNS ownership has been released.

AppGW, PIP, NSG/association and published DNS records retain `prevent_destroy`; disabling an existing deployment, clearing DNS publication or deleting the environment is blocked while they remain protected. Retire DNS/traffic and Helm consumers first, then use a reviewed code change to relax protection for the named resources, including DNS, and apply destruction through their owning platform state. Never remove state to bypass protection. For a pilot state handoff, freeze both runners, back up states, review ID/address mapping, transfer ownership without cloud deletion and verify a no-op destination plan before resuming. See the runbook.

## Constraints and retained evidence

- Terraform `>=1.9,<2.0`, AzureRM `4.81.0`; retained Azure API behavior tested at `2025-01-01`.
- Autoscale 1–2; public IP idle timeout ten minutes; TCP probes 80/443 at 20–21 seconds, timeout ten seconds, threshold three; backend timeout 600 seconds.
- No AppGW certificate, PROXY or original-client-IP preservation. Istio sees AppGW identity. Do not advertise per-client source-IP authorization; the separate authority-policy issue is [ENG-2502](https://linear.app/ryvn/issue/ENG-2502/match-i2gw-source-range-policies-for-concrete-host-authorities-with).
- AppGW config updates can interrupt connections; the retained canary observed one close. Moving the old pilot backend from its workload subnet to the planned frontend IP is a cutover requiring a disruption window, not a no-impact update.
- Microsoft Layer 4 overview/FAQ support wording conflicted during evaluation; successful provisioning does not establish GA support. Confirm terms before rollout.
- Observed US pricing estimated $238–296/month before IP, traffic and logging; confirm current pricing.
- Prior Guava public gRPC, WebSocket and controlled 335-second quiet/375-second heartbeat results are retained evidence, not ten-minute silence acceptance.
- Private Link transport/return/coexistence passed; private verified TLS remains UNVERIFIED with the placeholder certificate. Secure private gRPC/streaming/mTLS is DEFERRED to future Handshake validation; no customer mutation is authorized.

See the Ryvn monorepo's [rollout runbook](https://github.com/ryvn-technologies/ryvn/blob/main/docs-internal/runbooks/azure-application-gateway-ingress.md) and [current Azure design](https://github.com/ryvn-technologies/ryvn/blob/main/docs-internal/changes/cloud-egress-firewall/azure.md), plus [Guava implementation evidence](https://github.com/ryvn-technologies/ryvn/pull/9197). Internal docs are not copied into the published blueprints repository.

Microsoft documents the [static IPv4 annotation](https://learn.microsoft.com/en-us/azure/aks/internal-lb#specify-an-ip-address), [separate subnet](https://learn.microsoft.com/en-us/azure/aks/internal-lb#specify-a-different-subnet), [dedicated frontend subnet](https://learn.microsoft.com/en-us/azure/architecture/reference-architectures/containers/aks/baseline-aks#spoke-virtual-network) and [TCP/TLS proxy](https://learn.microsoft.com/en-us/azure/application-gateway/tcp-tls-proxy-overview).

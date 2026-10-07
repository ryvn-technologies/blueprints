# Azure Application Gateway TCP ingress

Opt-in `Standard_v2` public TCP 80/443 forwards to the existing external Istio gateway. Istio owns TLS, certificates, SNI/Host and routes. Azure Firewall remains default-deny egress. The internal gateway and Private Link frontend remain independent.

## Planned address, then runtime readiness

```text
Azure platform Terraform: application_gateway_enabled=true
  -> dedicated ingress-lb-subnet, fixed infrastructure slot 5
  -> application_gateway_network v2: backend{subnet_id,subnet_name,subnet_cidr,private_ip}
       +-> ryvn-gateway Helm values -> ryvn-agent -> Service -> AKS internal LB
       +-> platform child module -> AppGW backend pool (same root/state)
  -> gateway.public_ip -> gateway blueprint externalDNS.target
       -> existing external Service -> ExternalDNS
       -> i2gw Ingress status (when enabled) -> ExternalDNS without explicit targets
```

Both consumers use the same `cidrhost(subnet_cidr, 4)` IPv4. Terraform can configure AppGW before the Service exists. Infrastructure creation never waits on Kubernetes or backend health. There is no Kubernetes provider, Service/ConfigMap discovery, Helm output dependency or UID/address handoff.

The Azure AKS root invokes this module and owns its state. Enable `application_gateway_enabled: true` in the Azure environment config and provision the platform first. Its existing blueprint forwards config to Terraform and publishes outputs into environment state. On Azure, an enabled external gateway automatically consumes `application_gateway_network.enabled` and deploys its additional private Service. Missing/old output or `enabled: false` leaves gateway configuration unchanged. There is no separate AppGW Service, installation or gateway enable switch.

`application_gateway_enabled` and `egress_firewall.enabled` are independent and default false. For supported public ingress with managed egress filtering, operators explicitly enable both and keep `enableExternalGateway` enabled. Private-only environments can leave AppGW off. Terraform neither discovers gateway enablement nor couples the flags. Disabled AppGW creates no new subnet, IP or DNS. Existing infrastructure/node subnet names, CIDRs and Terraform addresses do not shift: slots 0/1 remain AppGW/Private Link, 2 service pool, 3 Postgres and 4 Firewall. Slot 5 is a separate additive resource, outside the service-pool and additional-subnet region. Both overlay and flat modes use the existing geometry. With current geometry, /16 and /19 produce /24 infrastructure subnets; /20–/24 are rejected because the unchanged AppGW subnet is too small or slot 5 does not fit. No network is automatically re-carved. Existing-VNet operators must confirm the reserved range is free before enabling.

## Platform API

| Azure environment config | Default | Purpose |
| --- | --- | --- |
| `application_gateway_enabled` | `false` | AppGW resources and dedicated ingress-LB subnet/IP |
| `application_gateway_name` | `null` → `appgw-<environment_name>` | Stable AppGW name; PIP/NSG use `pip-`/`nsg-` prefixes |

The version 2 `application_gateway_network` output contains `enabled`, subnet references, the planned `backend` descriptor and nullable `gateway{id,public_ip,public_ip_id,backend_ip,client_identity,proxy_protocol_enabled}`. These fields describe configured resources, not health. The child receives root resource/local references directly; subnet reads depend on subnet creation. It inherits the root AzureRM provider, already pinned to 4.81.0; no platform provider upgrade is required.

The frontend subnet has no implicit outbound access or route-table association and must not host node pools. Existing AKS VNet-scoped Network Contributor covers subnet read/join/network operations; no new RBAC or controller is introduced.

### Address lifecycle

The planned IP is an address contract, not an Azure reservation resource. AKS claims it when reconciling the Helm Service. Deleting the Service releases it; recreation requests the same annotation IP. Keep unrelated workloads from claiming it. Recovery still depends on AKS reconciliation and health checks. Do not use a dummy NIC or edit generated LB rules.

The chart requires the subnet name and private IPv4 and selects existing external gateway pods. It retains `Local`, TCP 80/443, AppGW subnet source restrictions, `/healthz`, ExternalDNS exclusion and the supported ten-minute idle-timeout annotation. It uses Azure's IPv4 annotation rather than deprecated `spec.loadBalancerIP`, and rejects internal attachment, PROXY and trusted forwarding headers.

## Ownership and activation

| Resource | Owner |
| --- | --- |
| Dedicated AppGW and ingress-LB subnets / planned IP contract | platform Terraform |
| AppGW, public IP, NSG/association | platform Terraform root/state, through this child module |
| Application A records and TXT registry ownership | existing ExternalDNS installations |
| Additional private Service | existing external `ryvn-gateway` Helm installation, deployed by `ryvn-agent` |
| Azure internal LB frontend, generated probes/rules/timeouts | AKS native controller |
| TLS, certificate Secrets, SNI/Host/routes | existing Istio, cert-manager and applications |
| Public self-call allows / default-deny egress | Azure Firewall policy |
| Internal frontend, PLS/PE, private DNS/NAT | existing Private Service owners |

Terraform only writes Azure objects; it never creates/patches/adopts Kubernetes or uses Helm/kubectl/local-exec wrappers. Existing Azure objects need reviewed import/state transfer; foreign NSGs and route-table associations fail. The dedicated backend subnet must match the contract and share the AppGW VNet.

ExternalDNS is the single application-DNS owner. Terraform exposes the public IP; the Azure external gateway blueprint passes it as `externalDNS.target`. The chart renders `external-dns.alpha.kubernetes.io/target` on the existing created or adopted public Service. Origin, wildcard, applicable apex and custom/operator hostname declarations stay authoritative. The additional private backend Service remains excluded. Internal gateways, internal HTTPS targets in public zones, Private Link and private zones are unchanged. No global ExternalDNS values or AWS/GCP zone filters change.

The managed AppGW target takes precedence over `service.annotations` and adopted-Service target overrides. `networking.ryvn.app/dns-target` marks that Service ownership. Adoption saves the previous explicit Service target in `networking.ryvn.app/original-dns-target`; removing the managed target restores it, or removes the target if none existed. An explicit target in the rollback adoption overlay takes precedence over the saved value. Unrelated annotations survive. For created Services, Istio's existing server-side apply removes its owned annotation when it disappears from the desired overlay. Direct chart operators can deliberately override `externalDNS.target`; ordinary Service target annotations cannot override the managed address. Blueprint consumers use the platform output rather than adding a second hostname list.

Ingress target annotations remain operator-owned and unchanged, including CDN hostnames and old ingress IPs. i2gw publishes the marked external Service's AppGW public IP only through Ingress status, when status publication is enabled; removing the managed Service target restores ordinary status derivation from the configured publish Service. In adopt mode, enable `externalPublishIngressStatus` (chart `ingressCompatibility.proxyTarget.publishIngressStatus`) after stopping the previous status publisher. Its default remains false; with publication disabled, i2gw leaves status unchanged. No target save/restore annotations are written to Ingresses.

Retained Guava ExternalDNS v0.19.0 enables Service and Ingress sources. [ExternalDNS v0.19.0](https://github.com/kubernetes-sigs/external-dns/blob/v0.19.0/source/ingress.go#L280-L284) prefers explicit target annotations over status, so review them manually before enablement: update old ingress addresses or the CDN origin as appropriate. The two Guava pilot overrides and proposed owner-controlled cleanup are documented in the [rollout runbook](https://github.com/ryvn-technologies/ryvn/blob/main/docs-internal/runbooks/azure-application-gateway-ingress.md#guava-pilot-ingress-overrides). Gateway/Route sources are absent from the retained configuration; audit any separately enabled source before rollout. Live deployment reads are currently forbidden, so retained arguments do not prove current release reconciliation. Existing add-on values may be snapshotted; changing defaults would not upgrade them.

DNS cutover follows gateway reconciliation, without a second Terraform apply or manual publication/ownership-attestation inputs. Bootstrap can temporarily have an unhealthy backend; IP existence and TCP probes do not prove TLS/routes or self-call readiness. Verify actual backend health, Istio certificates/routes and Firewall public self-call allows, then authoritative DNS across multiple reconciliation cycles. Pilot disruption is accepted. Certificate issuance/renewal and full published gateway/agent reconciliation remain rollout checks.

AppGW, PIP and NSG/association retain `prevent_destroy`; disabling an existing deployment or deleting the environment is blocked while they remain protected. Retire DNS/traffic and Helm consumers first, then use a reviewed code change to relax protection for the named Azure resources and apply destruction through their owning platform state. Never remove state to bypass protection. Applied Terraform DNS requires an explicit non-destructive ownership transfer to ExternalDNS before applying this removal: preserve records, targets and TXT registry ownership. Freeze runners, back up states and review `removed { lifecycle { destroy = false } }` plans. The retained `azurerm_dns_a_record.canary` is still owned by its standalone fixture state; it has not been transferred or deleted. See the runbook.

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

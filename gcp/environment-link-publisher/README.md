# Environment Link Publisher (GCP)

Publishes an environment's internal gateway to other environments over
Private Service Connect (PSC).

The internal gateway is a Kubernetes `LoadBalancer` Service that GKE backs
with an internal passthrough Network Load Balancer. This module puts a PSC
service attachment in front of that load balancer. Environments that run the
Environment Link Consumer module connect to the attachment and reach the
gateway's HTTP listener through it. The module needs no hostname: which names
callers use is up to their DNS.

## What it creates

| Resource | Purpose |
|----------|---------|
| PSC NAT subnet `<name_prefix>-psc-nat` (`nat_subnet_cidr`) | Source addresses for consumer connections. The gateway sees these addresses, not the consumers' own. |
| PSC service attachment `<name_prefix>` | Targets the internal gateway's forwarding rule. Connections are accepted only from `allowed_consumers`, or only from `project_id` when that list is empty. Changes to the list also apply to existing connections. |
| Firewall rule `<name_prefix>-psc-nat-allow-http` | Allows TCP 80 from the NAT subnet in `network`. |

The NAT subnet and service attachment come from Google's
[`private-service-connect-producer`](https://github.com/terraform-google-modules/terraform-google-network/tree/master/modules/private-service-connect-producer)
module.

## Finding the load balancer

GKE records the Service name in the description of the forwarding rule it
creates, for example `{"kubernetes.io/service-name":"ryvn-system/internal-ryvn-istio"}`.
The module lists the forwarding rules in `region` and keeps those on `network`
whose description names `gateway_service`. Planning fails unless exactly one
rule matches, its load balancing scheme is `INTERNAL`, and it serves port 80.

The port check matters because GKE recreates the forwarding rule when the
Service's ports change, and it can't while a service attachment uses the rule.
So the gateway must serve port 80 before this module is applied.

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `project_id` | GCP project of the environment. | required |
| `region` | Region of the internal gateway load balancer. | required |
| `network` | Self link of the environment's VPC network. | required |
| `name_prefix` | Prefix for resource names. Lowercase letters, digits and hyphens; starts with a letter and ends with a letter or digit. Prefixes over 40 characters are shortened and get a hash suffix. | required |
| `gateway_service` | Internal gateway Service, as `<namespace>/<name>`. | `ryvn-system/internal-ryvn-istio` |
| `nat_subnet_cidr` | IPv4 range of the PSC NAT subnet. Must not overlap the VPC's other ranges or anything routed to it. The default is outside RFC 1918 and Tailscale's `100.64.0.0/10`. | `198.18.0.0/28` |
| `allowed_consumers` | GCP project IDs allowed to connect. `"*"` is rejected. | `[]` (only `project_id`) |

## Outputs

| Name | Description |
|------|-------------|
| `publisher_id` | Service attachment ID: `projects/<project>/regions/<region>/serviceAttachments/<name>`. The consumer's `publisher_id` input. |

## Testing

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

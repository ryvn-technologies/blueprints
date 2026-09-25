# Environment Link Consumer (GCP)

Connects an environment to an Environment Link Publisher in another
environment over Private Service Connect (PSC). Workloads here resolve names
under the publisher's domain to a PSC endpoint in this environment's VPC, and
reach the publisher's internal gateway through it on TCP 80.

## What it creates

| Resource | Purpose |
|----------|---------|
| Internal address and PSC forwarding rule `<name_prefix>-psc-endpoint` | The PSC endpoint. It takes an IP from `subnetwork` and connects to the publisher's service attachment (`publisher_id`). |
| Firewall rule `<name_prefix>-endpoint-allow-http` (priority 900) | Allows egress on TCP 80 to the endpoint IP. |
| Firewall rule `<name_prefix>-endpoint-deny-other` (priority 910) | Denies all other egress to the endpoint IP. |
| Private DNS zone `<name_prefix>-publisher-domain` for `<publisher_domain>` | Attached to `network`. `*.<publisher_domain>` points at the endpoint IP. |

The address and forwarding rule come from Google's
[`private-service-connect-endpoints-for-published-services`](https://github.com/terraform-google-modules/terraform-google-network/tree/master/modules/private-service-connect-endpoints-for-published-services)
module. The endpoint is regional (no global access), so `subnetwork` must be in
the publisher's region. Planning fails if `subnetwork_region` isn't the region
in `publisher_id`.

## Inputs

| Name | Description |
|------|-------------|
| `project_id` | GCP project of the environment. |
| `network` | Self link of the environment's VPC network. |
| `subnetwork` | ID or self link of the subnet the endpoint takes its IP from. Must be in `network`. |
| `subnetwork_region` | Region of `subnetwork`. Must match the publisher's region. |
| `name_prefix` | Prefix for resource names. Lowercase letters, digits and hyphens; starts with a letter and ends with a letter or digit. Prefixes over 40 characters are shortened and get a hash suffix. |
| `publisher_id` | The publisher's `publisher_id` output: `projects/<project>/regions/<region>/serviceAttachments/<name>`. |
| `publisher_domain` | The internal domain of the publishing environment, whose names resolve to the endpoint. Lowercase, no trailing dot. |

All inputs are required.

## Outputs

| Name | Description |
|------|-------------|
| `consumer_id` | ID of the endpoint's forwarding rule: `projects/<project>/regions/<region>/forwardingRules/<name>`. |
| `link_state` | PSC connection status of the endpoint. `ACCEPTED` when connected. `PENDING` means this project isn't in the publisher's allowed consumers; `CLOSED` means the publisher's service attachment was removed. |

## Testing

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

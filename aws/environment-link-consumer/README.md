# Environment Link Consumer (AWS)

Connects an environment to an Environment Link Publisher in another
environment over AWS PrivateLink. Workloads here resolve names under the
publisher's domain to an interface endpoint in this environment's VPC, and
reach the publisher's internal gateway through it on TCP 80.

## What it creates

| Resource | Purpose |
|----------|---------|
| Interface endpoint `<name_prefix>-environment-link` | Connects to the publisher's endpoint service (`publisher_id`). It takes one subnet from `subnet_ids` per availability zone the service supports. Private DNS is off; the zone below handles names. |
| Security group `<name_prefix>-environment-link` | Allows TCP 80 to the endpoint from every CIDR associated with the VPC. Nothing else reaches it. |
| Private hosted zone for `<publisher_domain>` | Associated with `vpc_id`. `*.<publisher_domain>` is an alias to the endpoint's regional DNS name. |

The endpoint must be in the publisher's region. Planning fails if the region in
`publisher_id` isn't `region`, or if no subnet is in a zone the service
supports. It also fails if this account isn't in the publisher's allowed
consumers, because AWS then hides the service.

## Inputs

| Name | Description |
|------|-------------|
| `region` | Region of this environment's VPC. Must match the publisher's region. |
| `vpc_id` | VPC that gets the endpoint. |
| `subnet_ids` | Subnets the endpoint may use. |
| `name_prefix` | Prefix for resource names. Lowercase letters, digits and hyphens. |
| `publisher_id` | The publisher's `publisher_id` output: `com.amazonaws.vpce.<region>.vpce-svc-<id>`. |
| `publisher_domain` | The internal domain of the publishing environment, whose names resolve to the endpoint. Lowercase, no trailing dot. |

All inputs are required.

## Outputs

| Name | Description |
|------|-------------|
| `consumer_id` | ID of the interface endpoint: `vpce-<id>`. |
| `link_state` | State of the interface endpoint. `available` when connected. |

## Testing

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

# Environment Link Publisher (AWS)

Publishes an environment's internal gateway to other environments over AWS
PrivateLink.

The internal gateway is a Kubernetes `LoadBalancer` Service that the AWS Load
Balancer Controller backs with an internal Network Load Balancer. This module
puts a VPC endpoint service in front of that load balancer. Environments that
run the Environment Link Consumer module create an interface endpoint to it and
reach the gateway's HTTP listener through it. The module needs no hostname:
which names callers use is up to their DNS.

## What it creates

| Resource | Purpose |
|----------|---------|
| VPC endpoint service `<name>` | Fronts the internal gateway's Network Load Balancer. Endpoints from `allowed_consumers`, or from this account when that list is empty, are accepted without a manual step. |

## Finding the load balancer

The controller tags each load balancer with `elbv2.k8s.aws/cluster` and
`service.k8s.aws/stack` (`<namespace>/<name>` of the Service). The module looks
the load balancer up by those two tags. Planning fails unless exactly one
matches, and it is an internal Network Load Balancer.

Adding a port to the gateway Service adds a listener to the same load balancer,
so on AWS the endpoint service survives port changes. The gateway must serve
port 80 for HTTP callers to get through.

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `region` | Region of the internal gateway load balancer. | required |
| `cluster_name` | EKS cluster whose AWS Load Balancer Controller manages the load balancer. | required |
| `name` | Name tag of the endpoint service. Lowercase letters, digits and hyphens. | required |
| `gateway_service` | Internal gateway Service, as `<namespace>/<name>`. | `ryvn-system/internal-ryvn-istio` |
| `allowed_consumers` | 12-digit AWS account IDs allowed to connect. | `[]` (only this account) |

## Outputs

| Name | Description |
|------|-------------|
| `publisher_id` | Endpoint service name: `com.amazonaws.vpce.<region>.vpce-svc-<id>`. The consumer's `publisher_id` input. |

## Testing

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

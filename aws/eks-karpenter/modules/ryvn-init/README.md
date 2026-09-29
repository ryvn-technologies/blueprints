# ryvn-init (AWS)

Bootstraps Ryvn components on an EKS cluster from a CodeBuild run inside the
cluster's VPC. Today that is Cilium. The apply starts the build and waits for
it, so Terraform itself never calls the cluster's Kubernetes API and the API
endpoint can stay private.

## Switching an existing cluster

On a cluster that runs the VPC CNI, the same run moves every node to Cilium,
one at a time: cordon, drain (PodDisruptionBudgets are respected), hand over,
uncordon. Nodes stay on the VPC CNI until their turn, and pods on both kinds of
node reach each other over the VPC. The node being moved carries the label
`networking.ryvn.app/see-you-on-cilium=true`. The run stops before
`migration_timeout_seconds` runs out, and the next apply continues. A node whose
pods can't be moved stops the run and stays cordoned on the VPC CNI.

## Results, retries and repair

Each run writes `succeeded` or `failed: <reason>` to the SSM parameter
`/ryvn/<environment_name>/ryvn-init/result`, and the apply fails with that
reason. A failed result makes the next apply run the build again. Build logs
are in the CloudWatch log group `/ryvn/<environment_name>/ryvn-init`.

Once Ryvn has adopted the `cilium` release, a run leaves it alone and only
checks health. To reinstall these values anyway, set `cilium.repair = true`
and apply, or start a build without Terraform:

```bash
aws codebuild start-build --project-name ryvn-init-<environment_name> \
  --environment-variables-override name=RYVN_INIT_REPAIR,value=true
```

## Requirements

- Terraform 1.16 or later and AWS provider 6.15 or later.
- Private subnets with a NAT or another route to the internet (image and chart
  pulls). CodeBuild does not support subnets shared from another account.
- CodeBuild build capacity in the account. Brand-new accounts sometimes start
  with a concurrent-build quota of 0.
- The identity running Terraform can manage CodeBuild projects, IAM roles,
  EKS access entries, security groups, CloudWatch log groups and SSM
  parameters.

## Inputs and outputs

| Input | Description | Default |
|---|---|---|
| `environment_name` | Names the project, role, security group, log group and result parameter | required |
| `cluster_name` / `cluster_endpoint` / `cluster_certificate_authority_data` | Cluster to bootstrap | required |
| `cluster_security_group_id` | Security group on the cluster's API endpoint | required |
| `vpc_id` / `subnet_ids` | Where the build runs | required |
| `cilium` | `chart_version`, `values`, optional `repair` | required |
| `image` | ryvn-init image | required |
| `timeout_seconds` | Deadline for installing Cilium | `780` |
| `migration_timeout_seconds` | Extra time to move nodes from the VPC CNI to Cilium | `10800` |
| `iam_permissions_boundary_arn` / `tags` | Applied to what the module creates | `null` / `{}` |

Outputs: `role_arn` (cluster-admin through an EKS access entry),
`codebuild_project`, `log_group`, `result_parameter`.

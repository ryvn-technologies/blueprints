# ryvn-init (AWS)

Bootstraps Ryvn components on an EKS cluster from a CodeBuild run inside the
cluster's VPC: Cilium and, with `ryvn_agent`, the Ryvn agent. The apply starts
the build and waits for it, so Terraform itself never calls the cluster's
Kubernetes API and the API endpoint can stay private.

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

If PodDisruptionBudgets never allow evicting some pods, the run fails before
changing anything and names them. For a move agreed with the customer, set
`cilium.restart_pods_blocked_by_disruption_budgets = true` and apply, or start
the build below, to delete those pods once their node is cordoned instead.
Their workloads are down until the replacements are ready, and again if a
replacement lands on a node that hasn't moved yet. Pods without a controller
don't come back.

```bash
aws codebuild start-build --project-name ryvn-init-<environment_name> \
  --environment-variables-override name=RYVN_INIT_RESTART_PODS_BLOCKED_BY_DISRUPTION_BUDGETS,value=true
```

## Ryvn agent

With `ryvn_agent` set, a run installs the agent with any CNI, and with Cilium
it does so last. It fetches the agent's bundle from `hub_url`, using a
single-use token, before anything else, so the token spends little time in SSM.

The executor passes the token as the ephemeral input
`ryvn_agent_bootstrap_token`. Terraform writes it to the SecureString parameter
`/ryvn/<environment_name>/ryvn-init/agent-bootstrap-token` once the cluster
exists, through a write-only argument, so it stays out of plan and state. A new
`token_version` is what makes Terraform write it. The parameter has its own KMS
key, which only the identity running Terraform and the build can decrypt with.
The parameter isn't cleared afterwards: SSM keeps old versions, and the token
stops working once it is used or the apply ends.

Once the agent is installed, a run leaves it to Ryvn and doesn't read the token.
If the token was refused, the run fails. Provisioning again issues a new one.

Terraform decrypts the parameter on every refresh. If the identity running
Terraform changes to a different ARN, add it to the key policy first.

## Requirements

- Terraform 1.16 or later and AWS provider 6.15 or later.
- Private subnets with a NAT or another route to the internet (image and chart
  pulls). CodeBuild does not support subnets shared from another account.
- CodeBuild build capacity in the account. Brand-new accounts sometimes start
  with a concurrent-build quota of 0.
- The identity running Terraform can manage CodeBuild projects, IAM roles,
  EKS access entries, security groups, CloudWatch log groups, SSM parameters
  and, with `ryvn_agent`, KMS keys.

## Inputs and outputs

| Input | Description | Default |
|---|---|---|
| `environment_name` | Names the project, role, security group, log group and result parameter | required |
| `cluster_name` / `cluster_endpoint` / `cluster_certificate_authority_data` | Cluster to bootstrap | required |
| `cluster_security_group_id` | Security group on the cluster's API endpoint | required |
| `vpc_id` / `subnet_ids` | Where the build runs | required |
| `cilium` | `chart_version`, `values`, optional `repair` and `restart_pods_blocked_by_disruption_budgets`, or `null` to skip Cilium | `null` |
| `ryvn_agent` | `hub_url`, `token_version` and the `values` to add to the agent bundle's, or `null` to skip the agent | `null` |
| `ryvn_agent_bootstrap_token` | Ephemeral single-use token for the agent bundle | `null` |
| `executor_principal_arn` | IAM role or user running Terraform | required |
| `image` | ryvn-init image | required |
| `timeout_seconds` | Deadline for installing Cilium | `780` |
| `migration_timeout_seconds` | Extra time to move nodes from the VPC CNI to Cilium | `10800` |
| `iam_permissions_boundary_arn` / `tags` | Applied to what the module creates | `null` / `{}` |

Outputs: `role_arn` (cluster-admin through an EKS access entry),
`codebuild_project`, `log_group`, `result_parameter`.

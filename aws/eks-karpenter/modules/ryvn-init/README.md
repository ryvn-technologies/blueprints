# ryvn-init (AWS)

Bootstraps Ryvn components on an EKS cluster from a CodeBuild run inside the
cluster's VPC. Today that is Cilium. The apply starts the build and waits for
it, so Terraform itself never calls the cluster's Kubernetes API and the API
endpoint can stay private.

Ryvn's EKS platform module uses it, and any EKS module can call it:

```hcl
module "ryvn_init" {
  source = "github.com/ryvn-technologies/blueprints//aws/eks-karpenter/modules/ryvn-init?ref=<commit>"

  environment_name                   = "prod"
  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  cluster_security_group_id          = module.eks.cluster_security_group_id
  vpc_id                             = module.vpc.vpc_id
  subnet_ids                         = module.vpc.private_subnets
  image                              = "ryvn/init:0.1.0"

  cilium = {
    chart_version = "1.20.2"
    values        = local.cilium_values
  }
}
```

## Rules for the calling module

- Call it in the same configuration that creates the node groups, and don't
  make it depend on them: managed node groups only become ACTIVE once their
  nodes are Ready, which needs Cilium.
- Create the cluster without the `vpc-cni` add-on and put the
  `node.cilium.io/agent-not-ready=true:NoSchedule` taint on every node group.
  A first install waits until every node carries it.
- Render the Cilium values for the cluster (ENI IPAM, the operator's IAM role,
  subnets). `k8sServiceHost`/`k8sServicePort` are filled from the cluster
  endpoint when left empty.

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
| `timeout_seconds` | Deadline for one run | `780` |
| `iam_permissions_boundary_arn` / `tags` | Applied to what the module creates | `null` / `{}` |

Outputs: `role_arn` (cluster-admin through an EKS access entry),
`codebuild_project`, `log_group`, `result_parameter`.

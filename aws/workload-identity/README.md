# Workload Identity Module (AWS)

Gives Kubernetes workloads an AWS identity without static credentials. Each role group becomes one IAM role, trusted through EKS Pod Identity for the ServiceAccounts listed under it, with the group's managed policies attached. Resource modules (buckets, databases, queues) expose the policy ARNs they grant access with (for example the bucket module's `policy_arn` or the postgres module's `read_write_iam_policy_arn`); pass those ARNs, or any policy of your own, into `policy_arns`. The module never touches ServiceAccounts, pods, or the resources themselves.

## Usage

```hcl
module "workload_identity" {
  source = "./infra/ryvn-workload-identity/aws"

  name_prefix      = "prod-aws"
  environment      = "production"
  eks_cluster_name = "ryvn-eks-prod-aws"

  role_groups = {
    app = {
      associations = {
        api = {
          namespace       = "prod-aws"
          service_account = "api"
        }
        worker = {
          namespace       = "prod-aws"
          service_account = "worker"
        }
      }
      policy_arns = {
        media    = module.media_bucket.policy_arn
        postgres = module.postgres.read_write_iam_policy_arn
        custom   = aws_iam_policy.sqs_consumer.arn
      }
    }
  }
}
```

In a Ryvn blueprint, resolve the subjects from the installations themselves rather than typing names:

```yaml
role_groups:
  app:
    associations:
      worker:
        namespace:          '{{ (serviceInstallation "worker").namespace }}'
        service_account:    '{{ (serviceInstallation "worker").name }}'
    policy_arns:
      media: '{{ (blueprintInstallation "media").outputs.iamPolicyArn }}'
```

Ryvn's web-server and job charts name the ServiceAccount after the installation, so the installation name is the ServiceAccount name.

## What's Included

- **IAM role per group**: named `<name_prefix>-<role_name>` under `/ryvn/workloads/`, trusted by `pods.eks.amazonaws.com`. The trust policy carries one statement per subject, each conditioned on the Pod Identity session tags for that exact namespace and ServiceAccount pair, so the role is only assumable on behalf of the group's listed subjects.
- **Policy attachments**: every ARN in `policy_arns` attached to the group's role. Keys are yours; they only name the attachment in state, so keep them stable.
- **Pod Identity associations**: one per subject. Ryvn's pre-deploy hook runs as `<service_account>-pre-deploy`; list it as its own association when the hook needs the same access.

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `name_prefix` | Prefix for role names, typically the environment name | required |
| `environment` | Environment name, applied as a tag | required |
| `eks_cluster_name` | EKS cluster for the associations | required |
| `role_groups` | Map of groups; see the shape above | required |
| `aws_region` | AWS region | `"us-east-1"` |
| `tags` | Tags for all resources | `{}` |

## Outputs

| Name | Description |
|------|-------------|
| `role_arns` | Role ARN per group |
| `role_names` | Role name per group |
| `principals` | `[role ARN]` per group. Same output shape as the GCP and Azure modules |
| `association_ids` | Pod Identity association ID per subject |

## Prerequisites

- The EKS Pod Identity Agent add-on is installed on the cluster. Ryvn-provisioned clusters have it.
- The identity running Terraform can create IAM roles, attach policies, and manage Pod Identity associations.

## Notes

- **One group per ServiceAccount.** EKS allows one Pod Identity association per ServiceAccount per cluster. The variable validation rejects a namespace/ServiceAccount pair that appears more than once.
- **Policies live on the role.** Adding a resource means adding one more entry to `policy_arns`; the role and associations do not change and pods keep running. For permissions no resource module publishes, create an `aws_iam_policy` and pass its ARN, or attach to `role_names.<group>` outside the module.
- **Policy quota.** AWS attaches at most 10 managed policies to a role by default (20 with a quota increase).
- **Trust policy size.** IAM caps a role trust policy at 2048 characters by default (4096 with a quota increase). Each subject adds roughly 250 characters, so keep a group to about 8 subjects, or split it.
- **No wildcards.** Associations are exact namespace and ServiceAccount matches.
- **Ordering.** Install resource modules first so their policy ARNs exist. In a Ryvn blueprint the output references handle this.

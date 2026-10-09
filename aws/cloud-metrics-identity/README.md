# Cloud Metrics Reader Policy (AWS)

Creates the read-only IAM policy for the ryvn-collector's cloud-metrics pipeline and nothing else: `cloudwatch:GetMetricData`, `cloudwatch:GetMetricStatistics`, `cloudwatch:ListMetrics`, `tag:GetResources`, and `rds:DescribeDBInstances` (the capacity adapter's live allocation read) — all at `Resource: "*"` because AWS metric reads cannot be resource-scoped. Confinement is behavioral (the collector's tag filter + rendered allowlist) and auditable in the customer's CloudTrail.

This module deliberately does **not** create the role or the cluster binding — that is the shared `aws-workload-identity` module's job (`github.com/ryvn-technologies/blueprints//aws/workload-identity`), which binds via EKS Pod Identity. Wire this policy through its `role_groups[].policy_arns`:

```hcl
module "cloud_metrics_reader" {
  source = "github.com/ryvn-technologies/blueprints//aws/cloud-metrics-identity"

  name_prefix = "prod-aws"
  environment = "production"
}

module "workload_identity" {
  source = "github.com/ryvn-technologies/blueprints//aws/workload-identity"

  name_prefix      = "prod-aws"
  environment      = "production"
  eks_cluster_name = "ryvn-eks-prod-aws"

  role_groups = {
    cloud-metrics = {
      associations = {
        collector = { namespace = "observability", service_account = "ryvn-cloud-metrics-alloy" }
      }
      policy_arns = { reader = module.cloud_metrics_reader.policy_arn }
    }
  }
}
```

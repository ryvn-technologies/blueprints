# Read-only metric + tag-discovery permissions. AWS metric reads are
# all-or-nothing at Resource: "*" — no condition key applies to these actions
# (cloudwatch:namespace is PutMetricData-only), so the policy deliberately
# grants the minimum action set rather than a narrower resource scope that AWS
# cannot express.
data "aws_iam_policy_document" "reader" {
  statement {
    sid    = "CloudWatchMetricRead"
    effect = "Allow"

    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "TaggedResourceDiscovery"
    effect = "Allow"

    actions = [
      "tag:GetResources",
    ]

    resources = ["*"]
  }

  # The capacity adapter republishes AllocatedStorage (which CloudWatch
  # never emits as a metric) plus the autoscaling ceiling. The describe is
  # scopeable to RDS resources only — DB ARNs are unlistable in IAM, so it
  # lands on the service's wildcard resource with the same audit caveat as
  # the metric reads: every call shows in the customer's CloudTrail.
  statement {
    sid    = "RDSCapacityRead"
    effect = "Allow"

    actions = [
      "rds:DescribeDBInstances",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "reader" {
  name        = local.policy_name
  path        = "/ryvn/cloud-metrics/"
  description = "CloudWatch metric read + resource-group tag discovery for the ryvn-collector cloud-metrics pipeline"
  policy      = data.aws_iam_policy_document.reader.json

  tags = local.all_tags
}

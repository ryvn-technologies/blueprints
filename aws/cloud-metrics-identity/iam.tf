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
}

resource "aws_iam_policy" "reader" {
  name        = local.policy_name
  path        = "/ryvn/cloud-metrics/"
  description = "CloudWatch metric read + resource-group tag discovery for the ryvn-collector cloud-metrics pipeline"
  policy      = data.aws_iam_policy_document.reader.json

  tags = local.all_tags
}

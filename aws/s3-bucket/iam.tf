data "aws_iam_policy_document" "trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

resource "aws_iam_role" "bucket_access" {
  name_prefix        = substr("${local.bucket_name}-", 0, 32)
  path               = "/ryvn/buckets/"
  assume_role_policy = data.aws_iam_policy_document.trust.json

  tags = local.all_tags
}

locals {
  bucket_access_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = aws_s3_bucket.this.arn
      },
      {
        Sid    = "ObjectReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.this.arn}/*"
      },
      ], var.kms_key_arn == "" ? [] : [
      {
        Sid    = "BucketKeyUsage"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:ReEncrypt*",
        ]
        Resource = var.kms_key_arn
      },
    ])
  })
}

resource "aws_iam_role_policy" "bucket_access" {
  name   = "bucket-access"
  role   = aws_iam_role.bucket_access.id
  policy = local.bucket_access_policy
}

# Standalone grant for the workload identity module (role_groups.<group>.policy_arns).
resource "aws_iam_policy" "bucket_access" {
  name        = substr("${local.bucket_name}-access", 0, 128)
  path        = "/ryvn/buckets/"
  description = "Read/write access to the ${local.bucket_name} S3 bucket"
  policy      = local.bucket_access_policy

  tags = local.all_tags
}

locals {
  pod_identity_service_accounts = toset(flatten([
    for service_account in var.pod_identity_service_accounts : [
      trimspace(service_account),
      "${trimspace(service_account)}-pre-deploy",
    ] if trimspace(service_account) != ""
  ]))
}

resource "aws_eks_pod_identity_association" "this" {
  for_each = {
    for service_account in local.pod_identity_service_accounts :
    "${var.pod_identity_namespace}/${service_account}" => service_account
  }

  cluster_name    = var.cluster_name
  namespace       = var.pod_identity_namespace
  service_account = each.value
  role_arn        = aws_iam_role.bucket_access.arn

  tags = local.all_tags
}

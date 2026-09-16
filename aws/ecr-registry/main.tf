terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.6.0"

  backend "kubernetes" {}
}

provider "aws" {
  region = var.aws_region
}

resource "random_id" "suffix" {
  byte_length = 4
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_eks_node_groups" "this" {
  count = local.detect_node_identities ? 1 : 0

  cluster_name = var.cluster_name
}

data "aws_eks_node_group" "this" {
  for_each = local.detect_node_identities ? data.aws_eks_node_groups.this[0].names : toset([])

  cluster_name    = var.cluster_name
  node_group_name = each.value
}

data "aws_iam_role" "node" {
  for_each = toset(local.node_role_names)

  name = each.value
}

locals {
  # ECR repository names are lowercase [a-z0-9._/-], max 256 chars. Only the
  # base is truncated so the random suffix always survives.
  sanitized_name    = trim(substr(replace(lower(coalesce(var.registry_name, var.name_prefix)), "/[^a-z0-9._-]+/", "-"), 0, 64), "-._")
  base_name         = local.sanitized_name != "" ? local.sanitized_name : "registry"
  repository_prefix = "${local.base_name}-${random_id.suffix.hex}"
  account_id        = data.aws_caller_identity.current.account_id
  partition         = data.aws_partition.current.partition
  registry_host     = "${local.account_id}.dkr.ecr.${var.aws_region}.${data.aws_partition.current.dns_suffix}"

  # ECR repositories are created lazily by the copier under this prefix, so
  # every grant is scoped to the prefix rather than to individual repositories.
  repository_arn_pattern = "arn:${local.partition}:ecr:${var.aws_region}:${local.account_id}:repository/${local.repository_prefix}/*"

  all_tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment
    ManagedBy   = "ryvn"
  })

  # Node roles from EKS managed node groups are merged with the explicit list.
  # Karpenter-managed nodes and attached clusters must be passed explicitly.
  detect_node_identities = var.cluster_name != ""

  detected_node_role_names = local.detect_node_identities ? distinct([
    for ng in data.aws_eks_node_group.this : element(split("/", ng.node_role_arn), length(split("/", ng.node_role_arn)) - 1)
  ]) : []

  node_role_names = distinct(concat(var.node_role_names, local.detected_node_role_names))

  create_hub_read_role = var.hub_principal_arn != ""
}

# Guards the whole module: evaluated on plan so a misconfiguration fails before
# any IAM change is made.
resource "terraform_data" "preconditions" {
  input = local.repository_prefix

  lifecycle {
    precondition {
      condition     = !var.require_node_pull_grant || length(local.node_role_names) > 0
      error_message = "No node IAM roles were resolved for kubelet pull access. Set node_role_names explicitly (required for attached clusters and Karpenter-only clusters) or set require_node_pull_grant = false."
    }
  }
}

# ---------------------------------------------------------------------------
# Push identity: EKS Pod Identity role for the artifact copier
# ---------------------------------------------------------------------------

locals {
  pod_identity_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  push_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Login"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "CreateRepositoriesUnderPrefix"
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository",
          "ecr:TagResource",
        ]
        Resource = local.repository_arn_pattern
      },
      {
        Sid    = "PushAndPull"
        Effect = "Allow"
        Action = [
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:ListImages",
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = local.repository_arn_pattern
      },
    ]
  })

  pull_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Login"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PullUnderPrefix"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:ListImages",
        ]
        Resource = local.repository_arn_pattern
      },
    ]
  })

  hub_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.hub_principal_arn }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role" "push" {
  name_prefix        = substr("${local.repository_prefix}-push-", 0, 32)
  path               = "/ryvn/registries/"
  assume_role_policy = local.pod_identity_trust_policy
  tags               = local.all_tags
}

resource "aws_iam_role_policy" "push" {
  name   = "ecr-push"
  role   = aws_iam_role.push.id
  policy = local.push_policy
}

resource "aws_eks_pod_identity_association" "push" {
  for_each = var.cluster_name != "" ? toset(var.push_service_accounts) : toset([])

  cluster_name    = var.cluster_name
  namespace       = var.push_namespace
  service_account = each.value
  role_arn        = aws_iam_role.push.arn
  tags            = local.all_tags
}

# ---------------------------------------------------------------------------
# Pull identity: read-only policy attached to node roles
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "pull" {
  name_prefix = substr("${local.repository_prefix}-pull-", 0, 32)
  path        = "/ryvn/registries/"
  policy      = local.pull_policy
  tags        = local.all_tags
}

resource "aws_iam_role_policy_attachment" "node_pull" {
  for_each = toset(local.node_role_names)

  role       = data.aws_iam_role.node[each.key].name
  policy_arn = aws_iam_policy.pull.arn
}

# ---------------------------------------------------------------------------
# Optional hub read role: lets the Ryvn hub mint pull tokens for the registry
# (ElasticContainerRegistry definition with assumeRole credentials).
# ---------------------------------------------------------------------------

resource "aws_iam_role" "hub_read" {
  count = local.create_hub_read_role ? 1 : 0

  name_prefix        = substr("${local.repository_prefix}-hub-", 0, 32)
  path               = "/ryvn/registries/"
  assume_role_policy = local.hub_trust_policy
  tags               = local.all_tags
}

resource "aws_iam_role_policy_attachment" "hub_read" {
  count = local.create_hub_read_role ? 1 : 0

  role       = aws_iam_role.hub_read[0].name
  policy_arn = aws_iam_policy.pull.arn
}

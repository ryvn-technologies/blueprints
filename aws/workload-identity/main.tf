terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # optional() attribute defaults on the role_groups variable need 1.3+.
  required_version = ">= 1.3.0"

  backend "kubernetes" {}
}

provider "aws" {
  region = var.aws_region
}

locals {
  all_tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment
  })

  # Resolve each group's role name: explicit role_name wins, otherwise the map key.
  # IAM role names are capped at 64 characters.
  role_names = {
    for group_name, group in var.role_groups :
    group_name => substr("${var.name_prefix}-${coalesce(group.role_name, group_name)}", 0, 64)
  }

  # One entry per Kubernetes subject, keyed "<group>/<association key>".
  subjects = merge([
    for group_name, group in var.role_groups : {
      for assoc_key, assoc in group.associations :
      "${group_name}/${assoc_key}" => {
        group           = group_name
        namespace       = assoc.namespace
        service_account = assoc.service_account
      }
    }
  ]...)

  # Flatten policies across groups, keyed "<group>/<policy key>".
  policy_attachments = merge([
    for group_name, group in var.role_groups : {
      for policy_key, policy_arn in group.policy_arns :
      "${group_name}/${policy_key}" => {
        group      = group_name
        policy_arn = policy_arn
      }
    }
  ]...)
}

# One trust policy per group, with one statement per subject. EKS Pod Identity
# passes the namespace and ServiceAccount as session tags; pairing them in a
# single statement means the role can only be assumed on behalf of exactly the
# (namespace, ServiceAccount) pairs listed for its group, not any namespace
# combined with any ServiceAccount, even if an association is created elsewhere.
data "aws_iam_policy_document" "assume_role" {
  for_each = var.role_groups

  dynamic "statement" {
    for_each = { for key, subject in local.subjects : key => subject if subject.group == each.key }

    content {
      effect = "Allow"

      actions = [
        "sts:AssumeRole",
        "sts:TagSession",
      ]

      principals {
        type        = "Service"
        identifiers = ["pods.eks.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:RequestTag/kubernetes-namespace"
        values   = [statement.value.namespace]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:RequestTag/kubernetes-service-account"
        values   = [statement.value.service_account]
      }
    }
  }
}

# One IAM role per group. This is the principal the group's pods run as.
resource "aws_iam_role" "this" {
  for_each = var.role_groups

  name               = local.role_names[each.key]
  path               = "/ryvn/workloads/"
  assume_role_policy = data.aws_iam_policy_document.assume_role[each.key].json

  tags = merge(local.all_tags, {
    Name = local.role_names[each.key]
  })
}

# Managed policies attached to the group's role.
resource "aws_iam_role_policy_attachment" "this" {
  for_each = local.policy_attachments

  role       = aws_iam_role.this[each.value.group].name
  policy_arn = each.value.policy_arn
}

# Trust: one Pod Identity association per subject, mapping (cluster, namespace,
# ServiceAccount) to the group's role. EKS allows one association per
# ServiceAccount per cluster, which is why a ServiceAccount belongs to exactly
# one group.
resource "aws_eks_pod_identity_association" "this" {
  for_each = local.subjects

  cluster_name    = var.eks_cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.this[each.value.group].arn

  tags = local.all_tags
}
# Distributed to BYOC hubs as a public module (github.com/ryvn-technologies/blueprints).

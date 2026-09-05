# ============================================================================
# Ryvn agent
# ============================================================================
# The in-cluster agent that runs Terraform for the workload blueprints deployed
# into this environment. It assumes this role through IRSA, so the trust policy
# is scoped to the single service account it runs as.

resource "aws_iam_role" "ryvn_agent_role" {
  name                 = substr("RyvnAgentRole-${var.environment_name}", 0, 64)
  permissions_boundary = var.iam_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:${var.ryvn_system_namespace}:ryvn-agent"
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ryvn_agent_permissions" {
  role       = aws_iam_role.ryvn_agent_role.name
  policy_arn = aws_iam_policy.ryvn_agent_permissions.arn
}

# Two mutually exclusive shapes, selected by terraform_executor_policies:
#
#   default (empty list) — allow everything the provisioning path needs, then
#   explicitly deny the actions that read or move application data (secrets,
#   database rows, KMS plaintext) and the account-shaping ones (IAM users and
#   groups, Organizations). A Deny always wins, so the deny list is the actual
#   boundary.
#
#   caller-supplied — the statements passed in replace the allow/deny pair
#   wholesale, for accounts that require an explicitly enumerated policy.
#
# The IAM self-management block is unconditional: the agent creates the roles
# the workload modules need, so it must be able to manage roles either way.
resource "aws_iam_policy" "ryvn_agent_permissions" {
  name        = substr("RyvnAgentSelfManagement-${var.environment_name}", 0, 128)
  description = "Allow ryvn-agent to manage its own role permissions with restricted access to sensitive resources"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      length(var.terraform_executor_policies) == 0 ? [
        # Broad allow for provisioning actions
        {
          Effect   = "Allow"
          Action   = ["*"]
          Resource = "*"
        },
        # Explicit denies for sensitive operations
        {
          Effect = "Deny"
          Action = [
            # Secrets management
            "secretsmanager:*",
            "ssm:GetParameter*",
            "ssm:GetSecureParameter*",
            # Database data access operations
            "rds:ModifyCurrentDBClusterCapacity",
            "rds:FailoverDBCluster",
            "rds:FailoverGlobalCluster",
            "rds:StartDBInstance",
            "rds:StopDBInstance",
            "rds:RebootDBInstance",
            "rds:DeleteDBSnapshot",
            "rds:RestoreDBInstanceFromDBSnapshot",
            "rds:RestoreDBClusterFromSnapshot",
            "rds:RestoreDBInstanceToPointInTime",
            "rds:RestoreDBClusterToPointInTime",
            "dynamodb:BatchGetItem",
            "dynamodb:BatchWriteItem",
            "dynamodb:DeleteItem",
            "dynamodb:GetItem",
            "dynamodb:GetRecords",
            "dynamodb:PutItem",
            "dynamodb:Query",
            "dynamodb:Scan",
            "dynamodb:UpdateItem",
            "dynamodb:PartiQLDelete",
            "dynamodb:PartiQLInsert",
            "dynamodb:PartiQLSelect",
            "dynamodb:PartiQLUpdate",
            "redshift:*",
            # Sensitive KMS operations
            "kms:Decrypt",
            "kms:Encrypt",
            "kms:GenerateDataKey*",
            "kms:ReEncrypt*",
            "kms:ImportKeyMaterial",
            # Security services
            "securityhub:*",
            # IAM user/group management
            "iam:CreateUser",
            "iam:DeleteUser",
            "iam:CreateGroup",
            "iam:DeleteGroup",
            "iam:AddUserToGroup",
            "iam:RemoveUserFromGroup",
            # Organization management
            "organizations:*"
          ]
          Resource = "*"
        }
      ] : [],
      [
        # Allow specific IAM permissions needed for self-management and infra module provisioning
        {
          Effect = "Allow"
          Action = [
            "iam:AttachRolePolicy",
            "iam:CreatePolicy",
            "iam:CreateRole",
            "iam:DeletePolicy",
            "iam:DeleteRole",
            "iam:DeleteRolePermissionsBoundary",
            "iam:DeleteRolePolicy",
            "iam:DetachRolePolicy",
            "iam:GetPolicy",
            "iam:GetPolicyVersion",
            "iam:GetRole",
            "iam:GetRolePolicy",
            "iam:ListAttachedRolePolicies",
            "iam:ListInstanceProfilesForRole",
            "iam:ListPolicyVersions",
            "iam:ListRolePolicies",
            "iam:PassRole",
            "iam:PutRolePermissionsBoundary",
            "iam:PutRolePolicy",
            "iam:TagRole",
            "iam:UntagRole",
            "iam:UpdateRole"
          ]
          Resource = "*"
        }
      ],
      # Include terraform executor policies if specified
      length(var.terraform_executor_policies) > 0 ? [
        for policy in var.terraform_executor_policies : merge(
          {
            Effect = policy.effect
            Action = policy.actions
            Resource = (
              policy.resource != null ? [policy.resource] :
              policy.resources != null ? policy.resources :
              []
            )
          },
          policy.condition != null ? { Condition = policy.condition } : {}
        )
      ] : []
    )
  })
}

# ============================================================================
# external-dns
# ============================================================================
# Record writes are scoped to the two zones this module creates; the List*
# actions cannot be resource-scoped by Route 53 and are account-wide.

resource "aws_iam_role" "external_dns_role" {
  name                 = substr("ExternalDNSRole-${var.environment_name}", 0, 64)
  permissions_boundary = var.iam_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:external-dns:external-dns"
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "external_dns_policy" {
  count = var.skip_dns_provisioning ? 0 : 1
  name  = substr("ExternalDNSPolicy-${var.environment_name}", 0, 128)
  role  = aws_iam_role.external_dns_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = [
          "arn:${local.partition}:route53:::hostedzone/${aws_route53_zone.internal[0].zone_id}",
          "arn:${local.partition}:route53:::hostedzone/${aws_route53_zone.public[0].zone_id}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResources"
        ]
        Resource = [
          "*"
        ]
      }
    ]
  })
}

# ============================================================================
# AWS Load Balancer Controller
# ============================================================================
# Upstream's published policy, with partition-templated ARNs so it also applies
# in GovCloud and China. Kept in the controller's own JSON layout to stay
# diffable against the upstream document it tracks:
# https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

resource "aws_iam_role" "aws_load_balancer_controller_role" {
  name                 = substr("AWSLoadBalancerControllerRole-${var.environment_name}", 0, 64)
  permissions_boundary = var.iam_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "aws_load_balancer_controller_policy" {
  name = substr("AWSLoadBalancerControllerPolicy-${var.environment_name}", 0, 128)
  role = aws_iam_role.aws_load_balancer_controller_role.id

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "iam:CreateServiceLinkedRole"
        ],
        "Resource" : "*",
        "Condition" : {
          "StringEquals" : {
            "iam:AWSServiceName" : "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "ec2:GetSecurityGroupsForVpc",
          "ec2:DescribeIpamPools",
          "ec2:DescribeRouteTables",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeCapacityReservation"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateSecurityGroup"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateTags"
        ],
        "Resource" : "arn:${local.partition}:ec2:*:*:security-group/*",
        "Condition" : {
          "StringEquals" : {
            "ec2:CreateAction" : "CreateSecurityGroup"
          },
          "Null" : {
            "aws:RequestTag/elbv2.k8s.aws/cluster" : "false"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ],
        "Resource" : "arn:${local.partition}:ec2:*:*:security-group/*",
        "Condition" : {
          "Null" : {
            "aws:RequestTag/elbv2.k8s.aws/cluster" : "true",
            "aws:ResourceTag/elbv2.k8s.aws/cluster" : "false"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup"
        ],
        "Resource" : "*",
        "Condition" : {
          "Null" : {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" : "false"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup"
        ],
        "Resource" : "*",
        "Condition" : {
          "Null" : {
            "aws:RequestTag/elbv2.k8s.aws/cluster" : "false"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ],
        "Resource" : [
          "arn:${local.partition}:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ],
        "Condition" : {
          "Null" : {
            "aws:RequestTag/elbv2.k8s.aws/cluster" : "true",
            "aws:ResourceTag/elbv2.k8s.aws/cluster" : "false"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ],
        "Resource" : [
          "arn:${local.partition}:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
        ]
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyListenerAttributes",
          "elasticloadbalancing:ModifyCapacityReservation",
          "elasticloadbalancing:ModifyIpPools"
        ],
        "Resource" : "*",
        "Condition" : {
          "Null" : {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" : "false"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "elasticloadbalancing:AddTags"
        ],
        "Resource" : [
          "arn:${local.partition}:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ],
        "Condition" : {
          "StringEquals" : {
            "elasticloadbalancing:CreateAction" : [
              "CreateTargetGroup",
              "CreateLoadBalancer"
            ]
          },
          "Null" : {
            "aws:RequestTag/elbv2.k8s.aws/cluster" : "false"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets"
        ],
        "Resource" : "arn:${local.partition}:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:SetRulePriorities"
        ],
        "Resource" : "*"
      }
    ]
  })
}

# ============================================================================
# cert-manager
# ============================================================================
# Assumed via EKS Pod Identity (see the association in eks.tf) rather than
# IRSA. Record writes are restricted to TXT so the role can complete DNS-01
# challenges without being able to repoint live records.

resource "aws_iam_role" "cert_manager_role" {
  name                 = substr("CertManagerRole-${var.environment_name}", 0, 64)
  permissions_boundary = var.iam_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "cert_manager_policy" {
  name = substr("CertManagerPolicy-${var.environment_name}", 0, 128)
  role = aws_iam_role.cert_manager_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:${local.partition}:route53:::change/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = "arn:${local.partition}:route53:::hostedzone/*"
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsRecordTypes" = ["TXT"]
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = "route53:ListHostedZonesByName"
        Resource = "*"
      }
    ]
  })
}

# ============================================================================
# cluster-autoscaler (opt-in)
# ============================================================================
# Only created when var.cluster_autoscaler.enabled; Karpenter is the default
# node provisioner. Mutating actions are tagged-scoped to this cluster's
# Auto Scaling groups.

resource "aws_iam_role" "cluster_autoscaler_role" {
  count                = var.cluster_autoscaler.enabled ? 1 : 0
  name                 = substr("ClusterAutoscalerRole-${var.environment_name}", 0, 64)
  permissions_boundary = var.iam_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler_policy" {
  count = var.cluster_autoscaler.enabled ? 1 : 0
  name  = substr("ClusterAutoscalerPolicy-${var.environment_name}", 0, 128)
  role  = aws_iam_role.cluster_autoscaler_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeInstanceTypes",
          "eks:DescribeNodegroup",
          "ec2:DescribeImages",
          "ec2:GetInstanceTypesFromInstanceRequirements"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "autoscaling:UpdateAutoScalingGroup"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/kubernetes.io/cluster/${local.cluster_name}" = "owned"
          }
        }
      }
    ]
  })
}

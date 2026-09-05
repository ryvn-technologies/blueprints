locals {
  default_node_groups = {
    system = {
      instance_types = ["t4g.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      ami_type       = "AL2023_ARM_64_STANDARD"
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
      labels = {
        # Used to ensure Karpenter runs on nodes that it does not manage
        "karpenter.sh/controller" = "true"
      }
      taints = {
        critical_addons_only = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  default_cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni = {
      before_compute              = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    aws-efs-csi-driver = {
      service_account_role_arn = module.efs_csi_driver_irsa.iam_role_arn
    }
  }

  # Merge the user provided node groups with defaults, ensuring block_device_mappings are preserved
  eks_managed_node_groups = {
    for name, config in merge(local.default_node_groups, var.eks_managed_node_groups) :
    name => merge(
      # Start with the default configuration for this node group if it exists
      try(local.default_node_groups[name], {}),
      # Apply the user configuration

      config,
      # Always ensure labels are properly merged from defaults, user config, and required labels
      {
        labels = merge(
          try(local.default_node_groups[name].labels, {}),
          try(config.labels, {}),
          {
            "ryvn.app/node-group-name" = name
          }
        )
        # Each node group creates its own IAM role, so the boundary is set per group.
        # The environment-wide value takes precedence; a per-group value applies only
        # when no environment-wide boundary is configured.
        iam_role_permissions_boundary = (
          var.iam_permissions_boundary_arn != null
          ? var.iam_permissions_boundary_arn
          : try(config.iam_role_permissions_boundary, null)
        )
      }
    )
  }
}

locals {
  # Envelope-encryption KEK for the cluster. Ryvn provisioning a customer-managed key is the
  # default. In a landing-zone account where an SCP denies kms:CreateKey, create_cluster_kms_key =
  # false defers to EKS's AWS-owned key. The null is load-bearing: the EKS module keys
  # enable_encryption_config off `encryption_config != null`, so null removes the customer
  # encryption provider, the module's KMS submodule and the cluster role's encryption policy in one
  # move, and no kms:CreateKey is planned. Kubernetes API data stays envelope-encrypted either way
  # (EKS 1.28+ default with an AWS-owned key) and etcd stays disk-encrypted.
  cluster_encryption_config = var.create_cluster_kms_key ? { resources = ["secrets"] } : null
}

locals {
  # Maintenance access for whichever identity ran Terraform — RyvnAccessRole
  # when assume_role_arn was supplied, the external operator's own role
  # otherwise. Access entries need a durable principal, so role sessions
  # resolve to the issuing IAM role ARN via aws_iam_session_context rather
  # than the ephemeral STS session ARN.
  ryvn_access_entries = merge(
    {
      ryvn_maintenance_access = {
        kubernetes_groups = []
        principal_arn     = local.executor_principal_arn
        type              = "STANDARD"

        policy_associations = merge(
          {
            namespace_admin = {
              policy_arn = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
              access_scope = {
                namespaces = [var.ryvn_system_namespace]
                type       = "namespace"
              }
            }
            cluster_view = {
              policy_arn = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
              access_scope = {
                namespaces = []
                type       = "cluster"
              }
            }
          },
          var.cluster_bootstrap_perms ? {
            cluster_admin = {
              policy_arn = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
              access_scope = {
                type = "cluster"
              }
            }
          } : {}
        )
      }
    },
    var.cluster_access_entries
  )
}

module "eks" {
  source = "terraform-aws-modules/eks/aws"
  # >= 21.16.1 required for GovCloud: 21.16.0 added ECR Public policy ARN that doesn't exist in aws-us-gov (fixed in 21.16.1)
  version = ">= 21.16.1, < 22.0"

  name               = local.cluster_name
  kubernetes_version = var.cluster_version
  iam_role_name      = "${substr(local.cluster_name, 0, 29)}-cluster"

  iam_role_permissions_boundary = var.iam_permissions_boundary_arn

  # EKS Addons - deep merge vpc-cni to preserve before_compute and resolve_conflicts settings
  addons = merge(
    local.default_cluster_addons,
    var.cluster_addons,
    contains(keys(var.cluster_addons), "vpc-cni") ? {
      vpc-cni = merge(local.default_cluster_addons["vpc-cni"], var.cluster_addons["vpc-cni"])
    } : {}
  )

  vpc_id                   = local.vpc_id
  subnet_ids               = local.private_subnet_ids
  control_plane_subnet_ids = local.control_plane_subnet_ids

  # Provision a customer-managed KMS key as the envelope-encryption KEK by default.
  # create_cluster_kms_key = false defers to EKS's AWS-owned key (no kms:CreateKey), for accounts
  # whose SCP denies key creation. Secrets stay envelope-encrypted either way on EKS 1.28+.
  create_kms_key    = var.create_cluster_kms_key
  encryption_config = local.cluster_encryption_config

  # Pinned rather than left to the module default so node-to-API traffic stays
  # in-VPC. Under BYO transit gateway egress the public endpoint would otherwise
  # route node traffic out through the existing inspection path.
  endpoint_private_access = true

  # The public endpoint stays reachable from the Ryvn control plane's static
  # egress addresses so it can reconcile the cluster, plus whatever the caller
  # allows. Everything else is denied.
  endpoint_public_access = true
  endpoint_public_access_cidrs = concat(
    var.cluster_endpoint_public_access_cidrs,
    [
      "3.225.179.159/32",
      "3.85.154.126/32",
      "54.152.86.243/32"
    ]
  )
  enable_irsa = true

  # Configure executor maintenance access merged with additional access entries
  access_entries = local.ryvn_access_entries

  # Extend cluster security group rules
  security_group_additional_rules = {
    egress_nodes_ephemeral_ports_tcp = {
      description                = "To node 1025-65535"
      protocol                   = "tcp"
      from_port                  = 1025
      to_port                    = 65535
      type                       = "egress"
      source_node_security_group = true
    }
  }

  # Extend node-to-node security group rules
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Control plane to worker nodes on all ports. Admission webhooks are served
    # from workload pods on arbitrary ports (metrics-server 4443,
    # karpenter 8443, third-party mutating webhooks anywhere), and a narrower
    # rule has to be extended for every add-on that adds one. Tighten this to
    # the specific ports in use if your security posture requires it.
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  node_security_group_tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = local.cluster_name
  })

  eks_managed_node_groups = local.eks_managed_node_groups

  create_cloudwatch_log_group = var.create_cloudwatch_log_group
  enabled_log_types           = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = local.tags
}

module "ebs_csi_driver_irsa" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  # >= 5.47.1 required for GovCloud: 5.47.0 hardcoded arn:aws:ec2 in EBS CSI policy (fixed in 5.47.1)
  version = ">= 5.47.1, < 6.0"

  role_name_prefix = "ryvn-eks-ebs-csi-driver-"

  role_permissions_boundary_arn = var.iam_permissions_boundary_arn

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

module "efs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = ">= 5.47.1, < 6.0"

  role_name_prefix = "ryvn-eks-efs-csi-driver-"

  role_permissions_boundary_arn = var.iam_permissions_boundary_arn

  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "kube-system:efs-csi-controller-sa",
        "kube-system:efs-csi-node-sa"
      ]
    }
  }
}

# Add client mount permissions for EFS access points
resource "aws_iam_role_policy" "efs_csi_driver_client_mount" {
  name = substr("EFSCSIDriverClientMount-${var.environment_name}", 0, 128)
  role = module.efs_csi_driver_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite"
        ]
        Resource = "*"
      }
    ]
  })
}

# Pod Identity association for cert-manager
resource "aws_eks_pod_identity_association" "cert_manager" {
  cluster_name    = module.eks.cluster_name
  namespace       = "cert-manager"
  service_account = "cert-manager"
  role_arn        = aws_iam_role.cert_manager_role.arn
}

# Pod Identity association for cluster-autoscaler
resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  count           = var.cluster_autoscaler.enabled ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler_role[0].arn
}

# User-defined Pod Identity associations
resource "aws_eks_pod_identity_association" "user_defined" {
  for_each        = var.pod_identity_associations
  cluster_name    = module.eks.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = each.value.role_arn
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = ">= 21.16.1, < 22.0"

  cluster_name = module.eks.cluster_name

  # Name needs to match role name passed to the EC2NodeClass
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = local.cluster_name
  create_pod_identity_association = true

  iam_role_permissions_boundary_arn  = var.iam_permissions_boundary_arn
  node_iam_role_permissions_boundary = var.iam_permissions_boundary_arn

  # Use inline policy to avoid the 6,144 character limit on standard IAM managed policies.
  # Long cluster names cause the generated policy to exceed this limit.
  enable_inline_policy = true

  # Used to attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

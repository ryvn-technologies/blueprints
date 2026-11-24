module "runner" {
  source = "./modules/runner"

  cluster_name                 = module.eks.cluster_name
  cluster_security_group_id    = module.eks.cluster_security_group_id
  vpc_id                       = local.vpc_id
  name_prefix                  = var.runner_name_prefix
  iam_permissions_boundary_arn = var.iam_permissions_boundary_arn
  tags                         = local.tags
}

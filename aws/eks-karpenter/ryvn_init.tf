locals {
  # The platform blueprint sets every other Cilium value (var.cilium_values).
  cilium_values_from_cluster = {
    eni = {
      iamRole = one(aws_iam_role.cilium_operator_role[*].arn)
      # Limits leaked-ENI cleanup to this cluster; Cilium's cluster.name is "default" everywhere.
      gcTags = { "io.cilium/cluster-name" = module.eks.cluster_name }
      nodeSpec = {
        # IDs take priority over tags, so only one of them is ever set.
        subnetIDs  = local.workload_subnet_discovery_ids
        subnetTags = [for key, value in local.workload_subnet_discovery_tags : "${key}=${value}"]
      }
    }
    operator = {
      extraEnv = [{ name = "AWS_DEFAULT_REGION", value = var.region }]
    }
  }

  cilium_values = var.cni != "cilium" ? null : merge(var.cilium_values, {
    eni = merge(try(var.cilium_values.eni, {}), {
      iamRole  = local.cilium_values_from_cluster.eni.iamRole
      gcTags   = merge(try(var.cilium_values.eni.gcTags, {}), local.cilium_values_from_cluster.eni.gcTags)
      nodeSpec = merge(try(var.cilium_values.eni.nodeSpec, {}), local.cilium_values_from_cluster.eni.nodeSpec)
    })
    operator = merge(try(var.cilium_values.operator, {}), {
      extraEnv = concat(try(var.cilium_values.operator.extraEnv, []), local.cilium_values_from_cluster.operator.extraEnv)
    })
  })
}

# Must not depend on the node groups: they only become ACTIVE once nodes are
# Ready, which needs Cilium.
module "ryvn_init" {
  source = "./modules/ryvn-init"
  count  = var.cni == "cilium" ? 1 : 0

  environment_name                   = var.environment_name
  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  cluster_security_group_id          = module.eks.cluster_security_group_id
  vpc_id                             = local.vpc_id
  subnet_ids                         = local.node_subnet_ids
  image                              = var.ryvn_init_image
  timeout_seconds                    = var.ryvn_init_timeout_seconds
  migration_timeout_seconds          = var.ryvn_init_migration_timeout_seconds

  cilium = {
    chart_version                              = var.cilium_chart_version
    values                                     = local.cilium_values
    repair                                     = var.cilium_repair
    restart_pods_blocked_by_disruption_budgets = var.cilium_restart_pods_blocked_by_disruption_budgets
  }

  iam_permissions_boundary_arn = var.iam_permissions_boundary_arn
  tags                         = local.tags

  depends_on = [aws_iam_role_policy.cilium_operator_policy]
}

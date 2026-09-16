output "registry_host" {
  description = "ECR registry endpoint host (<account>.dkr.ecr.<region>.amazonaws.com)"
  value       = local.registry_host
}

output "registry_id" {
  description = "ECR registry id (the AWS account id)"
  value       = local.account_id
}

output "repository_prefix" {
  description = "Repository namespace under which mirrored artifacts are pushed. The copier creates repositories lazily beneath it."
  value       = local.repository_prefix
}

output "destination_base" {
  description = "Base image reference under which mirrored artifacts are pushed: <host>/<prefix>"
  value       = "${local.registry_host}/${local.repository_prefix}"
}

output "path_prefix" {
  description = "Path prepended to the source image path when pulling from this registry (RegistryMirror.pathPrefix)"
  value       = local.repository_prefix
}

output "region" {
  description = "AWS region of the registry"
  value       = var.aws_region
}

output "registry_definition" {
  description = "Registry definition in the shape of the Ryvn registry API. Uses ElasticContainerRegistry with assumeRole credentials when a hub role exists, otherwise a GenericContainerRegistry with clusterDefault credentials. Contains no secrets."
  value = jsondecode(local.create_hub_read_role ? jsonencode({
    type   = "elasticContainerRegistry"
    url    = local.registry_host
    region = var.aws_region
    credentials = {
      type    = "assumeRole"
      roleArn = aws_iam_role.hub_read[0].arn
    }
    }) : jsonencode({
    type = "genericContainerRegistry"
    url  = local.registry_host
    credentials = {
      type = "clusterDefault"
    }
  }))
}

output "push_identity" {
  description = "Non-secret description of how the artifact copier authenticates to push"
  value = {
    method          = "eksPodIdentity"
    namespace       = var.push_namespace
    serviceAccounts = var.push_service_accounts
    roleArn         = aws_iam_role.push.arn
    associated      = var.cluster_name != ""
  }
}

output "pull_identity" {
  description = "Non-secret description of how cluster nodes authenticate to pull"
  value = {
    method    = "awsNodeRole"
    roleNames = local.node_role_names
    policyArn = aws_iam_policy.pull.arn
    detected  = local.detect_node_identities
  }
}

output "hub_read_role_arn" {
  description = "ARN of the role the Ryvn hub assumes to read from the registry, or empty when not created"
  value       = local.create_hub_read_role ? aws_iam_role.hub_read[0].arn : ""
}

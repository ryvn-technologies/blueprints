output "cluster_endpoint" {
  description = "Endpoint for your Kubernetes API server"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster for the OpenID Connect identity provider"
  value       = module.eks.cluster_oidc_issuer_url
  sensitive   = true
}

output "cluster_platform_version" {
  description = "Platform version for the cluster"
  value       = module.eks.cluster_platform_version
}

output "cluster_service_cidr" {
  description = "The CIDR block where Kubernetes pod and service IP addresses are assigned from"
  value       = module.eks.cluster_service_cidr
}

output "cluster_version" {
  description = "The Kubernetes version for the cluster"
  value       = module.eks.cluster_version
}

output "cluster_status" {
  description = "Status of the EKS cluster"
  value       = module.eks.cluster_status
}

output "cluster_region" {
  description = "The AWS region where the EKS cluster is deployed"
  value       = var.region
}

output "ryvn_agent_role_arn" {
  description = "ARN of the RyvnAgentRole"
  value       = aws_iam_role.ryvn_agent_role.arn
}

output "aws_load_balancer_controller_role_arn" {
  value       = aws_iam_role.aws_load_balancer_controller_role.arn
  description = "ARN of the IAM role for AWS Load Balancer Controller"
}

output "external_dns_role_arn" {
  value       = aws_iam_role.external_dns_role.arn
  description = "ARN of the IAM role for external-dns"
}

output "cert_manager_role_arn" {
  value       = aws_iam_role.cert_manager_role.arn
  description = "ARN of the IAM role for cert-manager"
}

output "cluster_autoscaler_role_arn" {
  description = "ARN of the IAM role for cluster-autoscaler"
  value       = var.cluster_autoscaler.enabled ? aws_iam_role.cluster_autoscaler_role[0].arn : null
}

output "public_domain" {
  description = "The public domain for the cluster"
  value = var.skip_dns_provisioning ? null : {
    name        = aws_route53_zone.public[0].name
    id          = aws_route53_zone.public[0].zone_id
    nameservers = aws_route53_zone.public[0].name_servers
  }
}

output "internal_domain" {
  description = "The internal domain for the cluster"
  value = var.skip_dns_provisioning ? null : {
    name = aws_route53_zone.internal[0].name
    id   = aws_route53_zone.internal[0].zone_id
  }
}

output "karpenter" {
  description = "Karpenter Setup Outputs"
  value = {
    queue_name = module.karpenter.queue_name
    namespace  = module.karpenter.namespace
  }
}

# The network contract. Identical in shape whether Ryvn created the VPC or the
# caller supplied it — downstream consumers must never have to branch on who
# owns it. Values come from the normalized locals in network.tf.
output "vpc" {
  value = {
    name = local.vpc_name
    id   = local.vpc_id
    cidr = local.vpc_cidr_primary
    azs  = local.network_azs

    # All CIDR associations, primary first. `cidr` above stays the primary for
    # back-compat; consumers building SG rules or proxy trust lists should read
    # this instead — a BYO VPC's workloads may sit in a secondary association.
    cidrs = local.vpc_cidrs

    private_subnet_cidr_blocks = local.private_subnet_cidr_blocks
    private_subnet_ids         = local.private_subnet_ids

    # True only when the subnets are pre-existing and Ryvn could not put its
    # discovery tags on them, so consumers that resolve subnets by tag
    # (Karpenter, the AWS load balancer controller) must be given IDs instead.
    # Absent from the state of every environment provisioned before this
    # output existed, which templates read as false — the tagged case.
    subnet_discovery_by_id_required = local.byo_subnets_enabled

    # Empty under internal-only egress (BYO transit_gateway / nat_gateway).
    public_subnet_cidr_blocks = local.public_subnet_cidr_blocks
    public_subnet_ids         = local.public_subnet_ids
    default_security_group_id = local.default_security_group_id

    # Ryvn-provisioned VPCs only. In BYO the TGW attachment is pre-existing.
    transit_gateway_subnet_ids         = aws_subnet.transit_gateway[*].id
    transit_gateway_subnet_cidr_blocks = aws_subnet.transit_gateway[*].cidr_block
    transit_gateway_route_table_id     = length(local.tgw_subnets) > 0 ? aws_route_table.transit_gateway[0].id : null

    nat_public_ips = local.outbound_ips
  }
  description = "A map of vpc attributes: name, id, cidr, cidrs, azs, private_subnet_cidr_blocks, private_subnet_ids, subnet_discovery_by_id_required, public_subnet_cidr_blocks, public_subnet_ids, default_security_group_id."
}

output "outbound_ips" {
  description = "Public IPs used for outbound internet traffic from workloads in this environment. Empty when outbound_ips_known is false."
  value       = local.outbound_ips
}

output "outbound_ips_known" {
  description = "Whether Ryvn can determine this environment's outbound IPs. False under BYO transit gateway egress, where traffic leaves through a centralized egress path and the addresses live in another account — an empty outbound_ips is then 'managed elsewhere', not 'none'."
  value       = local.outbound_ips_known
}

output "cluster_node_security_group_id" {
  description = "Security group ID attached to the EKS cluster nodes"
  value       = module.eks.node_security_group_id
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "cluster_secrets_encryption" {
  description = "Envelope encryption for this cluster's Kubernetes API data, which is always on (EKS 1.28+ default with an AWS-owned key; etcd is also disk-encrypted). customer_managed_key is true when Ryvn provisions a customer-managed KMS key as the KEK; key_arn is that key, or null when EKS's AWS-owned key is used."
  value = {
    customer_managed_key = var.create_cluster_kms_key
    key_arn              = var.create_cluster_kms_key ? module.eks.kms_key_arn : null
  }
}

output "control_plane_logging" {
  description = "EKS control-plane log emission metadata: CloudWatch log group name + ARN and the set of enabled log types."
  value = {
    # Prefer the upstream module's output (set when create_cloudwatch_log_group = true);
    # fall back to the EKS-fixed path when the operator pre-creates the group themselves.
    log_group_name    = coalesce(module.eks.cloudwatch_log_group_name, "/aws/eks/${module.eks.cluster_name}/cluster")
    log_group_arn     = coalesce(module.eks.cloudwatch_log_group_arn, "arn:${local.partition}:logs:${var.region}:${var.account_id}:log-group:/aws/eks/${module.eks.cluster_name}/cluster")
    enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  }
}

output "addons" {
  description = "Per-addon outputs keyed by EKS addon name. role_arn is the IAM role the addon's service account runs as (IRSA), after any cluster_addons override, so it can be used to attach additional policies."
  value = {
    aws-ebs-csi-driver = {
      role_arn = try(module.eks.cluster_addons["aws-ebs-csi-driver"].service_account_role_arn, null)
    }
    aws-efs-csi-driver = {
      role_arn = try(module.eks.cluster_addons["aws-efs-csi-driver"].service_account_role_arn, null)
    }
  }
}

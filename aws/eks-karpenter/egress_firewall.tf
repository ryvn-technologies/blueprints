locals {
  firewall_enabled = var.egress_firewall.enabled
  # Subnets for anything that boots and pulls images (node groups, bootstrap
  # jobs): the same private subnets, but published only once the firewall
  # default routes and NAT return paths exist.
  node_subnet_ids = local.firewall_enabled ? one(module.egress_network[*].cluster_subnet_ids) : local.private_subnet_ids
  builtin_platform_https_domains = toset([
    "api.ecr.${var.region}.amazonaws.com",
    "*.dkr.ecr.${var.region}.amazonaws.com",
    "s3.${var.region}.amazonaws.com",
    "prod-${var.region}-starport-layer-bucket.s3.${var.region}.amazonaws.com",
    "ec2.${var.region}.amazonaws.com",
    "ec2messages.${var.region}.amazonaws.com",
    # ECR Public API (GetAuthorizationToken from the node credential provider;
    # observed blocked from Bottlerocket/Karpenter nodes in isolated testing).
    "api.ecr-public.${var.region}.amazonaws.com",
    # ECR Public's token API and pricing API only exist in us-east-1.
    "api.ecr-public.us-east-1.amazonaws.com",
    "eks.${var.region}.amazonaws.com",
    "eks-auth.${var.region}.amazonaws.com",
    "eks-auth.${var.region}.api.aws",
    "oidc.eks.${var.region}.amazonaws.com",
    "sts.${var.region}.amazonaws.com",
    "sqs.${var.region}.amazonaws.com",
    "ssm.${var.region}.amazonaws.com",
    "ssmmessages.${var.region}.amazonaws.com",
    "pricing.${var.region}.amazonaws.com",
    "api.pricing.${var.region}.amazonaws.com",
    "api.pricing.us-east-1.amazonaws.com",
    "public.ecr.aws",
    "d2glxqk2uabbnd.cloudfront.net",
    "d5l0dvt14r5h8.cloudfront.net",
    "auth.docker.io",
    "registry-1.docker.io",
    # Hub canonicalizes Docker Hub OCI chart repos to index.docker.io
    # (pkg/registry.CanonicalHost); docker.io is the same registry's short name.
    "index.docker.io",
    "docker.io",
    "production.cloudflare.docker.com",
    "production.cloudfront.docker.com",
    "docker-images-prod.s3.dualstack.${var.region}.amazonaws.com",
    "registry.k8s.io",
    "prod-registry-k8s-io-${var.region}.s3.dualstack.${var.region}.amazonaws.com",
    "ghcr.io",
    "pkg-containers.githubusercontent.com",
    # Istio images: registry.istio.io redirects to a region-local Artifact
    # Registry host (e.g. us-west2-docker.pkg.dev).
    "registry.istio.io",
    "*.pkg.dev",
    "gcr.io",
    # Ryvn's public chart repository and registry.
    "charts.ryvn.app",
    "registry.ryvn.app",
    "iam.amazonaws.com",
    # ryvn-init (CodeBuild in the private subnets) pulls the Cilium chart and the
    # nodes pull Cilium images from quay.io; blob downloads redirect to cdnNN.quay.io.
    "quay.io",
    "*.quay.io",
    # CodeBuild build agent log delivery and the ryvn-init result parameter.
    "logs.${var.region}.amazonaws.com",
    # AWS Load Balancer Controller (blocked with a native ALERT in isolated testing).
    "elasticloadbalancing.${var.region}.amazonaws.com",
    "shield.us-east-1.amazonaws.com",
    # external-dns and cert-manager DNS-01 (global Route 53 endpoint).
    "route53.amazonaws.com",
    # cert-manager HTTP-01/DNS-01 ACME issuer.
    "acme-v02.api.letsencrypt.org",
  ])
  # Caller-supplied hub/collector hostnames join the built-ins; they can add to
  # the baseline but never remove from it.
  platform_https_domains = setunion(
    local.builtin_platform_https_domains,
    [for domain in var.platform_https_domains : trimsuffix(lower(trimspace(domain)), ".")],
  )

  # Every subnet the root layout owns now or may create later (/20 slots 0..12
  # on a /16, public, intra, NAT, firewall), so a workload group can never
  # take one.
  cluster_slot_cidrs = local.byo_enabled ? [] : concat(
    flatten(module.vpc[*].private_subnets_cidr_blocks),
    flatten(module.vpc[*].public_subnets_cidr_blocks),
    flatten(module.vpc[*].intra_subnets_cidr_blocks),
    local.additional_workload_subnet_slots[*].cidr_block,
    values(local.egress_nat_subnet_cidrs),
    values(local.egress_firewall_subnet_cidrs),
  )
  egress_nat_subnet_cidrs      = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, 56 + i) }
  egress_firewall_subnet_cidrs = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 12, 960 + i) }

  additional_subnet_groups_by_name  = { for group in var.additional_subnet_groups : group.name => group }
  retired_additional_subnet_groups  = [for group in var.additional_subnet_groups : group.name if group.retired]
  attached_additional_subnet_groups = distinct(values(var.egress_attachments)[*].subnet_group_key)
  # Active but unassigned groups: kept disjoint from firewall sources, never
  # part of HOME_NET and never routed through the firewall or NAT.
  unattached_workload_subnet_cidrs = local.byo_enabled ? [] : flatten([
    for name, group in module.workload_subnet_groups[0].groups : [for p in values(group.subnets_by_az) : p.ipv4_cidr]
    if !contains(local.attached_additional_subnet_groups, name)
  ])
}

# Network layer: Ryvn-owned external workload subnet groups (subnet, dedicated
# route table and association per group/AZ, VPC-local routing only). Exists
# in both firewall modes; the firewall child only adds routes to attached
# groups' tables.
module "workload_subnet_groups" {
  source = "./workload_subnet_groups"
  count  = local.byo_enabled ? 0 : 1

  name           = "ryvn-${var.environment_name}"
  vpc_id         = local.vpc_id
  vpc_cidr       = var.vpc_cidr
  azs            = local.azs
  tags           = local.tags
  reserved_cidrs = local.cluster_slot_cidrs
  groups         = var.additional_subnet_groups
}

output "additional_subnet_groups" {
  description = "Network inventory of active external workload subnet groups keyed by name: per-AZ subnet_id, ipv4_cidr and route_table_id. Not a readiness token: a group listed here is only protected once an egress_attachments entry assigns it and egress_firewall.attachments publishes it."
  value       = local.byo_enabled ? {} : module.workload_subnet_groups[0].groups
}

moved {
  from = terraform_data.egress_firewall_compatibility[0]
  to   = terraform_data.egress_firewall_compatibility
}

# Always present so disabled mode can also reject firewall-only inputs.
resource "terraform_data" "egress_firewall_compatibility" {
  lifecycle {
    precondition {
      condition     = local.firewall_enabled || length(var.egress_attachments) == 0
      error_message = "egress_attachments needs egress_firewall.enabled = true; with the firewall disabled nothing would protect those subnets."
    }
    precondition {
      condition     = !local.firewall_enabled || (!local.byo_enabled && var.egress_mode == "create_nat" && !coalesce(var.create_s3_gateway_endpoint, false))
      error_message = "Managed egress firewall requires a Ryvn-owned VPC, no external egress mode and no S3 gateway endpoint bypass."
    }
    # The firewall's in-cluster counterpart is Cilium policy, and its source
    # set is Cilium's ENI IPAM drawing from the protected subnets exported
    # below. This checks the declared target only: it says nothing about
    # whether Cilium is installed or healthy, which the cluster stage proves.
    precondition {
      condition     = !local.firewall_enabled || var.cni == "cilium"
      error_message = "Managed egress firewall requires cni = cilium; it is not supported on the VPC CNI."
    }
    precondition {
      condition     = !local.firewall_enabled || !contains(keys(var.egress_attachments), "cluster") && alltrue([for p in values(var.egress_attachments) : contains(keys(var.egress_firewall.policies), p.policy_key)])
      error_message = "External attachment policy keys must exist and cluster is reserved."
    }
    precondition {
      condition     = alltrue([for p in values(var.egress_attachments) : contains(keys(local.additional_subnet_groups_by_name), p.subnet_group_key) && p.subnet_group_key != "cluster"])
      error_message = "egress_attachments subnet_group_key must name an additional_subnet_groups entry (known: ${join(", ", keys(local.additional_subnet_groups_by_name))}); the built-in cluster group cannot be attached as an external class."
    }
    precondition {
      condition     = alltrue([for p in values(var.egress_attachments) : !contains(local.retired_additional_subnet_groups, p.subnet_group_key)])
      error_message = "egress_attachments references retired additional_subnet_groups (${join(", ", [for p in values(var.egress_attachments) : p.subnet_group_key if contains(local.retired_additional_subnet_groups, p.subnet_group_key)])}); remove the attachment before retiring a group."
    }
    precondition {
      condition     = length(local.attached_additional_subnet_groups) == length(var.egress_attachments)
      error_message = "Each additional_subnet_groups entry can be assigned to at most one egress_attachments entry, even with the same policy_key."
    }
    precondition {
      condition     = local.byo_enabled ? length(var.additional_subnet_groups) == 0 : true
      error_message = "additional_subnet_groups requires a Ryvn-owned VPC."
    }
    precondition {
      condition     = !local.firewall_enabled || !var.enable_transit_gateway_subnets && length(var.transit_gateway_subnets) == 0 && var.vpc_cidr == cidrsubnet(var.vpc_cidr, 0, 0) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
      error_message = "Firewall subnet layout requires a VPC of /16 or larger without transit-gateway subnets."
    }
  }
}

module "egress_network" {
  source = "./egress_network"
  count  = local.firewall_enabled ? 1 : 0

  name      = "ryvn-${var.environment_name}"
  vpc_id    = local.vpc_id
  vpc_cidr  = var.vpc_cidr
  vpc_cidrs = local.vpc_cidrs
  igw_id    = one(module.vpc[*].igw_id)
  azs       = local.azs
  tags      = local.tags
  cluster_subnets_by_az = {
    for i, az in local.azs : az => {
      subnet_id      = module.vpc[0].private_subnets[i]
      ipv4_cidr      = module.vpc[0].private_subnets_cidr_blocks[i]
      route_table_id = module.vpc[0].private_route_table_ids[i]
    }
  }
  cluster_source_cidrs_by_az = {
    for az in local.azs : az => [for subnet in values(aws_subnet.additional_workload) : subnet.cidr_block if subnet.availability_zone == az]
  }
  # Public, intra, every not-yet-created cluster growth slot and every
  # unassigned workload group: none may overlap a firewall source.
  reserved_subnet_cidrs = concat(
    flatten(module.vpc[*].public_subnets_cidr_blocks),
    flatten(module.vpc[*].intra_subnets_cidr_blocks),
    local.workload_subnet_cidrs_above_count,
    local.unattached_workload_subnet_cidrs,
  )
  nat_subnet_cidrs      = local.egress_nat_subnet_cidrs
  firewall_subnet_cidrs = local.egress_firewall_subnet_cidrs
  subnet_groups = {
    for name, group in module.workload_subnet_groups[0].groups : name => { subnets_by_az = group.subnets_by_az }
    if contains(local.attached_additional_subnet_groups, name)
  }
  attachments            = var.egress_attachments
  cluster_policy_key     = var.egress_firewall.cluster_policy_key
  policies               = var.egress_firewall.policies
  platform_https_domains = local.platform_https_domains
  change_protection      = var.egress_firewall.change_protection

  # The root owns the cluster default routes (aws_route.private_default).
  cluster_default_route_ids = { for i, az in local.azs : az => aws_route.private_default[tostring(i)].id }

  depends_on = [terraform_data.egress_firewall_compatibility]
}

output "egress_firewall" {
  description = "Configured firewall policy, effective rules and protected external compute attachment descriptors. Disabled mode returns the same object shape with enabled = false and empty diagnostics."
  value = {
    enabled            = local.firewall_enabled
    default_action     = local.firewall_enabled ? "deny" : null
    cluster_policy_key = local.firewall_enabled ? var.egress_firewall.cluster_policy_key : null
    platform_baseline  = local.firewall_enabled ? sort(tolist(local.platform_https_domains)) : []
    # Stable identity -> SID and provenance for every compiled pass rule.
    effective_rules     = local.firewall_enabled ? module.egress_network[0].effective_rules : {}
    attachments         = local.firewall_enabled ? module.egress_network[0].attachments : {}
    nat_public_ips      = local.firewall_enabled ? module.egress_network[0].nat_public_ips : []
    firewall_endpoints  = local.firewall_enabled ? module.egress_network[0].firewall_endpoint_ids : {}
    alert_log_group     = local.firewall_enabled ? module.egress_network[0].alert_log_group : null
    flow_log_group      = local.firewall_enabled ? module.egress_network[0].flow_log_group : null
    s3_gateway_endpoint = local.firewall_enabled ? "disabled: S3 uses inspected NAT path" : null
    cni                 = var.cni
    change_protection   = local.firewall_enabled ? var.egress_firewall.change_protection : null
    firewall_arn        = local.firewall_enabled ? module.egress_network[0].firewall_arn : null
    nat_route_table_ids = local.firewall_enabled ? module.egress_network[0].nat_route_table_ids : {}
    # Primary cluster subnets only: the EKS/load-balancer selector (and the
    # Cilium eni.nodeSpec.subnetIDs candidate), not the whole inspected pool.
    cluster_subnet_ids = local.firewall_enabled ? module.egress_network[0].cluster_subnet_ids : []
    # Every subnet whose ENIs are inspected: primary cluster subnets, additional
    # workload subnets and attachment subnets. A node or pod ENI outside this set
    # is outside the firewall's source set.
    protected_subnet_ids = local.firewall_enabled ? concat(
      module.egress_network[0].cluster_subnet_ids,
      [for subnet in values(aws_subnet.additional_workload) : subnet.id],
      flatten([for attachment in values(module.egress_network[0].attachments) : [for placement in values(attachment.subnets_by_az) : placement.subnet_id]]),
    ) : []
    vpc_cidrs = local.firewall_enabled ? local.vpc_cidrs : []
  }
}

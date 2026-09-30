locals {
  cilium_values = {
    eni = {
      enabled                   = true
      awsReleaseExcessIPs       = true
      awsEnablePrefixDelegation = false
      iamRole                   = one(aws_iam_role.cilium_operator_role[*].arn)
      # Scopes dangling-ENI GC to this cluster.
      gcTags = {
        "io.cilium/cilium-managed" = "true"
        "io.cilium/cluster-name"   = module.eks.cluster_name
      }
      nodeSpec = {
        firstInterfaceIndex = 0
        # IDs take priority over tags, so only one of them is ever set.
        subnetIDs  = local.workload_subnet_discovery_ids
        subnetTags = [for key, value in local.workload_subnet_discovery_tags : "${key}=${value}"]
      }
    }
    ipam        = { mode = "eni" }
    routingMode = "native"

    # Istio ambient chains its own CNI plugin, and BPF masquerading breaks its
    # health probes: https://istio.io/latest/docs/ambient/install/platform-prerequisites/#cilium
    cni = { exclusive = false }
    bpf = { masquerade = false }
    # For Istio once kube-proxy replacement is on; no effect until then:
    # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#socket-loadbalancer-bypass-in-pod-namespace
    socketLB = { hostNamespaceOnly = true }
    # Keeps EKS's kube-proxy add-on, as on VPC CNI clusters; replacing it moves
    # all Service handling into Cilium, which we haven't tested yet:
    # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
    # Must be a string; the chart rejects a boolean.
    kubeProxyReplacement = "false"

    policyEnforcementMode   = "default"
    l7Proxy                 = true
    k8sNetworkPolicy        = { enabled = true }
    k8sClusterNetworkPolicy = { enabled = true }
    nodeSelectorLabels      = true

    hubble            = { enabled = false }
    ingressController = { enabled = false }
    gatewayAPI        = { enabled = false }

    # Agents read these values only at startup; restart them when they change.
    rollOutCiliumPods = true

    # Nodes still on the VPC CNI keep it until ryvn-init moves them to Cilium.
    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{
            matchExpressions = [{ key = "io.cilium/aws-node-enabled", operator = "NotIn", values = ["true"] }]
          }]
        }
      }
    }

    # Envoy is intentionally off for now: domain rules only need the agent's DNS proxy.
    # TODO(NominalTrajectory): fix the startup deadlock before turning Envoy on, since Helm waits for
    # Envoy pods that can't schedule on nodes still on the VPC CNI.
    envoy = { enabled = false }

    operator = {
      hostNetwork = true
      dnsPolicy   = "Default"
      # It would restart CoreDNS pods on nodes still on the VPC CNI; ryvn-init moves those nodes.
      unmanagedPodWatcher = { restart = false }
      extraEnv = [
        { name = "AWS_DEFAULT_REGION", value = var.region },
      ]
      # Chart defaults plus CriticalAddonsOnly; Helm replaces lists.
      tolerations = [
        for key in [
          "node-role.kubernetes.io/control-plane",
          "node-role.kubernetes.io/master",
          "node.kubernetes.io/not-ready",
          "node.cloudprovider.kubernetes.io/uninitialized",
          "CriticalAddonsOnly",
          "node.cilium.io/agent-not-ready",
        ] : { key = key, operator = "Exists" }
      ]
    }
  }
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

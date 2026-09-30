variable "environment_name" {
  type        = string
  description = "Environment name to be used as a suffix"
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "account_id" {
  type        = string
  description = "AWS account ID for where the cluster should be provisioned"
}

variable "partition" {
  type        = string
  default     = "aws"
  description = "AWS partition (aws, aws-us-gov, aws-cn). Unused — retained so existing callers that still pass it stay valid; ARNs derive from data.aws_partition."
}

variable "assume_role_arn" {
  description = "ARN of the IAM role to assume for AWS operations. Leave null to run on the caller's ambient identity (external executors)."
  type        = string
  default     = null
}

variable "internal_root_domain" {
  type        = string
  description = "Internal domain for services using networking node internal"
}

variable "public_root_domain" {
  type        = string
  description = "Public domain for services using networking node public"
}

variable "cluster_version" {
  type    = string
  default = "1.34"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC Ryvn creates. Ignored when existing_vpc_id is set — the carve derives from the existing VPC's actual CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "egress_firewall" {
  description = "Optional managed VPC default-deny egress. Disabled mode retains the existing network. Enabled mode requires cni = cilium. policies[*].domain_allow is a map of named rules: a non-empty set of bare DNS names (exact, or a leading *. suffix), protocol https (TLS on 443, matched on SNI) or http (plain HTTP on 80, matched on Host), and optional destination_ports defaulting to that port; v1 accepts only https+443 and http+80. Any other destination needs a named network_allow entry (IPv4 CIDRs, protocol, destination ports, reason). change_protection sets AWS Network Firewall's native delete/subnet-change protection only."
  type = object({
    enabled            = bool
    change_protection  = optional(bool, true)
    default_action     = optional(string, "deny")
    cluster_policy_key = optional(string, "cluster")
    policies = optional(map(object({
      domain_allow = optional(map(object({
        domains           = set(string)
        protocol          = string
        destination_ports = optional(set(number))
      })), {})
      network_allow = optional(map(object({
        destination_ipv4_cidrs = set(string)
        protocol               = string
        destination_ports      = set(number)
        reason                 = string
      })), {})
    })), {})
  })
  default = { enabled = false }

  validation {
    condition     = !var.egress_firewall.enabled || (var.egress_firewall.default_action == "deny" && contains(keys(var.egress_firewall.policies), var.egress_firewall.cluster_policy_key))
    error_message = "Enabled egress_firewall requires default_action deny and an existing cluster_policy_key."
  }
}

variable "platform_https_domains" {
  description = <<-EOT
    Additional exact DNS hostnames the cluster's platform components reach over HTTPS/443
    (the managing Ryvn hub API and issuer, the observability collector's Loki/Mimir gateways
    and token endpoint, an access tunnel). Added to, never replacing, the built-in AWS and
    registry baseline; compiled for cluster sources only, so additional_subnet_groups do not
    inherit them even on the cluster policy key. Bare lower-case hostnames only: no scheme,
    path, port, wildcard or IP literal. The Ryvn AWS platform blueprint derives these from
    the managing hub automatically; standalone callers list them explicitly. Ignored while
    egress_firewall.enabled = false.
  EOT
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for domain in var.platform_https_domains :
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]([a-z0-9-]{0,61}[a-z0-9])?[.]?$", lower(trimspace(domain))))
    ])
    error_message = "platform_https_domains entries must be bare multi-label DNS hostnames (e.g. api.hub.example): no scheme, path, port, wildcard or IP literal."
  }
}

variable "additional_subnet_groups" {
  description = <<-EOT
    Ordered, append-only list of named Ryvn-owned subnet groups for compute that runs OUTSIDE the
    cluster (one subnet per group and availability zone), allocated deterministically from a
    reserved area after the cluster's fixed layout. Unlike workload_subnets_per_az, these subnets
    carry no cluster, Karpenter or Cilium discovery and never join cluster routing or policy.
    Never edit, reorder, resize, rename or remove an entry once applied (the plan is rejected,
    and the allocation records carry prevent_destroy): append a new group for more capacity
    and set retired = true to tombstone one that is no longer used. The tombstone is permanent,
    its address span stays reserved and is never returned to the budget. Tearing down a whole
    environment needs the deliberate procedure in workload_subnet_groups/README.md. Groups exist
    independently of egress_firewall.enabled and have only VPC-local routing until an
    egress_attachments entry assigns them a policy.
  EOT
  type = list(object({
    name               = string
    ipv4_prefix_length = number
    availability_zones = list(string)
    retired            = optional(bool, false)
  }))
  default = []
}

variable "egress_attachments" {
  description = "Named external compute classes: each assigns one additional_subnet_groups entry (subnet_group_key) to one egress_firewall policy (policy_key). No CIDRs and no subnet creation here; requires egress_firewall.enabled = true."
  type = map(object({
    subnet_group_key = string
    policy_key       = string
  }))
  default = {}
}

variable "workload_subnets_per_az" {
  description = "Cluster workload subnets per availability zone (1-4). Raise it to get more IP addresses for nodes and pods inside the cluster's discovery, routing and egress policy. It can't be lowered. Subnets for compute outside the cluster are additional_subnet_groups."
  type        = number
  default     = 1

  validation {
    condition     = var.workload_subnets_per_az >= 1 && var.workload_subnets_per_az <= 4 && floor(var.workload_subnets_per_az) == var.workload_subnets_per_az
    error_message = "workload_subnets_per_az must be a whole number from 1 to 4."
  }
}

variable "existing_vpc_id" {
  description = "ID of an existing VPC to provision into (BYO VPC). When set, Ryvn skips VPC creation and either carves its standard subnet layout inside this VPC (carve mode) or consumes the subnets named by existing_workload_subnet_ids (subnets mode). Leave null to have Ryvn create the VPC."
  type        = string
  default     = null
}

variable "existing_workload_subnet_ids" {
  description = <<-EOT
    IDs of pre-existing private subnets to run nodes and pods in. Setting this selects BYO
    subnets mode: Ryvn creates no subnets, route tables, routes, associations or NAT, and tags
    nothing it does not own. For accounts where a central authority owns the network and denies
    topology mutation (SCP-restricted landing zones, RAM-shared VPCs).

    Requires existing_vpc_id, at least two AZs, and a pre-existing 0.0.0.0/0 route in each
    subnet's route table. Karpenter is configured with these IDs directly, so no discovery tag on
    them is needed; load balancer discovery tags are the network owner's to apply. Leave empty to carve.
  EOT
  type        = list(string)
  default     = []
}

variable "existing_control_plane_subnet_ids" {
  description = "IDs of pre-existing subnets for the EKS control-plane ENIs. Only used in BYO subnets mode; defaults to existing_workload_subnet_ids, which EKS accepts. Must span at least two AZs."
  type        = list(string)
  default     = []
}

variable "existing_public_subnet_ids" {
  description = "IDs of pre-existing public subnets for internet-facing load balancers. Only used in BYO subnets mode. Leave empty when the network is internal-only — the common case for centralized-egress accounts — and internet-facing Services will have nowhere to place an ELB."
  type        = list(string)
  default     = []
}

variable "min_free_ips_per_workload_subnet" {
  description = "Minimum free IP addresses required in each subnet named by existing_workload_subnet_ids. Under the VPC CNI every pod consumes a subnet IP, so this is the floor below which a subnet cannot usefully host nodes. Lower it only for deliberately small environments."
  type        = number
  default     = 16
}

variable "create_cluster_kms_key" {
  description = <<-EOT
    Whether Ryvn provisions a customer-managed KMS key to serve as the envelope-encryption key
    encryption key (KEK) for the cluster. Default true.

    Kubernetes API data, including Secrets, is envelope-encrypted regardless of this setting: EKS
    1.28+ enables default envelope encryption with an AWS-owned key, and etcd is disk-encrypted on
    every cluster. This toggle only chooses the KEK — a customer-managed key Ryvn creates (true, the
    default, for defense-in-depth and the ability to revoke access by disabling the key), or EKS's
    AWS-owned key (false).

    Set false in landing-zone accounts whose SCP denies kms:CreateKey — the same accounts that own
    the network and need existing_*_subnet_ids. With false, no kms:CreateKey is attempted and EKS
    uses its AWS-owned key; nothing is left unencrypted.
  EOT
  type        = bool
  default     = true
}

variable "egress_mode" {
  description = <<-EOT
    How 0.0.0.0/0 leaves the carved subnets. Only used when existing_vpc_id is set.

    - transit_gateway: route to an existing transit gateway (centralized egress). Internal-only —
      no NAT, no internet gateway, no public subnets. The VPC must already have an available
      attachment to that TGW; a VPC with no subnets cannot be pre-attached, so the attachment
      subnets and the attachment itself must exist before provisioning.
    - nat_gateway: route to an existing NAT gateway. Internal-only.
    - create_nat: Ryvn creates public subnets, an EIP and a NAT gateway. Requires an internet
      gateway already attached to the VPC. Not available in BYO subnets mode, which creates no
      subnets and no routes for a NAT to be reachable through.

    In BYO subnets mode the mode describes routing that already exists rather than routing Ryvn
    creates, and egress_target_id is optional there — it is only needed to report the
    environment's outbound IPs and to check TGW attachment AZ coverage.
  EOT
  type        = string
  default     = "create_nat"

  validation {
    condition     = contains(["transit_gateway", "nat_gateway", "create_nat"], var.egress_mode)
    error_message = "egress_mode must be one of: transit_gateway, nat_gateway, create_nat."
  }
}

variable "egress_target_id" {
  description = "Egress target for the carved workload subnets: a transit gateway ID (tgw-...) when egress_mode is transit_gateway, or a NAT gateway ID (nat-...) when egress_mode is nat_gateway. Unused for create_nat."
  type        = string
  default     = null
}

variable "create_s3_gateway_endpoint" {
  description = <<-EOT
    Whether to create an S3 gateway endpoint on the private route table, so S3 traffic
    (including every ECR image layer) takes the AWS backbone instead of the NAT gateway.
    Gateway endpoints are free.

    Null means on for a Ryvn-provisioned VPC and off for a BYO VPC, whose network design and
    egress path belong to the customer. Set false to opt a Ryvn-provisioned VPC out. Setting
    true alongside existing_vpc_id is rejected.

    Once the endpoint exists, S3 requests from the environment no longer originate from the NAT
    gateway's public IP. S3 bucket policies elsewhere that allow this environment by outbound_ips
    must allow its VPC instead (an aws:SourceVpc condition).
  EOT
  type        = bool
  default     = null
}

variable "s3_gateway_endpoint_policy" {
  description = <<-EOT
    JSON policy document for the S3 gateway endpoint. Null attaches AWS's default, which allows
    every request. An endpoint policy can only narrow what IAM and bucket policies already
    permit, so the default leaves authorization exactly where it is today. Set this in accounts
    that scope every endpoint to their organization (aws:PrincipalOrgID, aws:ResourceOrgID); a
    scoped policy must still allow the ECR layer buckets
    (arn:aws:s3:::prod-<region>-starport-layer-bucket/*), or image pulls fail.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.s3_gateway_endpoint_policy == null || can(jsondecode(var.s3_gateway_endpoint_policy))
    error_message = "s3_gateway_endpoint_policy must be a JSON policy document."
  }
}

variable "byo_workload_subnet_cidrs" {
  description = "Explicit CIDR blocks for the carved workload subnets, one per availability zone. Leave empty to use the standard layout derived from the existing VPC's CIDR. Set this when the head of the VPC range is already occupied, naming free blocks instead."
  type        = list(string)
  default     = []
}

variable "byo_control_plane_subnet_cidrs" {
  description = "Explicit CIDR blocks for the carved EKS control-plane subnets, one per availability zone. Leave empty to use the standard layout."
  type        = list(string)
  default     = []
}

variable "byo_public_subnet_cidrs" {
  description = "Explicit CIDR blocks for the carved public subnets, one per availability zone. Only used when egress_mode is create_nat. Leave empty to use the standard layout."
  type        = list(string)
  default     = []
}

variable "ryvn_system_namespace" {
  type        = string
  default     = "ryvn-system"
  description = "Namespace that the break glass role should have admin access to"
}

variable "cluster_bootstrap_perms" {
  type        = bool
  default     = false
  description = "If true, grants cluster admin permissions to the Terraform executor identity for initial setup. Should be disabled after bootstrap."
}

variable "eks_managed_node_groups" {
  description = "Map of EKS managed node group definitions to create. Values will be merged with defaults if not specified."
  type        = any
  default     = {}
}

variable "create_cloudwatch_log_group" {
  type        = bool
  default     = false
  description = "Whether to create a new CloudWatch log group for EKS cluster logging"
}

variable "terraform_executor_policies" {
  description = "Additional IAM policy statements to be added to the Ryvn Agent role. Each policy statement should include Effect, Action, and Resource."
  type = list(object({
    effect  = string
    actions = list(string)
    # For backward compatibility, we allow 'resources' to be a list of strings
    resources = optional(list(string))
    # resource is the name that matches aws
    resource = optional(any)
    # IAM policy condition block, e.g. { "StringEquals" = { "kms:ViaService" = "secretsmanager.us-east-1.amazonaws.com" } }
    condition = optional(any)
  }))
  default = []
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Additional CIDR blocks which can access the Amazon EKS public API server endpoint. The provisioner's egress addresses are always allowed; if not specified, no other source is."
  type        = list(string)
  default     = []
}

variable "provisioner_egress_cidrs" {
  description = "Outbound addresses of the provisioner that provisions this environment. It installs and reconciles the agent over the public API server endpoint, so these addresses are always allowed. Defaults to the hosted control plane; a self-hosted one passes its own."
  type        = list(string)
  default = [
    "3.225.179.159/32",
    "3.85.154.126/32",
    "54.152.86.243/32"
  ]
}

variable "enable_flow_log" {
  description = "Whether to enable VPC Flow Logs"
  type        = bool
  default     = false
}

variable "skip_dns_provisioning" {
  description = "Skip provisioning DNS managed zones"
  type        = bool
  default     = false
}

variable "cluster_addons" {
  description = "Map of cluster addon configurations. Will be merged with default configurations."
  type        = any
  default     = {}
}

variable "cni" {
  description = "Cluster CNI: vpc-cni or cilium."
  type        = string
  default     = "vpc-cni"

  validation {
    condition     = contains(["vpc-cni", "cilium"], var.cni)
    error_message = "cni must be one of: vpc-cni, cilium."
  }
}

variable "ryvn_init_image" {
  description = "ryvn-init image used when cni = \"cilium\". Set by the platform blueprint."
  type        = string
  # Not required: environments on an older platform blueprint don't pass it.
  default = null

  validation {
    condition     = var.cni != "cilium" || var.ryvn_init_image != null
    error_message = "ryvn_init_image is required when cni is cilium."
  }
}

variable "ryvn_init_timeout_seconds" {
  description = "Deadline for installing Cilium; must stay under EKS's 15-minute NotReady node limit."
  type        = number
  default     = 780
}

variable "ryvn_init_migration_timeout_seconds" {
  description = "Extra time to move nodes from the VPC CNI to Cilium, one at a time, when cni changes to cilium. Keep it under the lifetime of the credentials Terraform runs with."
  type        = number
  default     = 10800
}

variable "cilium_chart_version" {
  description = "Cilium chart version (oci://quay.io/cilium/charts/cilium). Set by the platform blueprint."
  type        = string
  # Not required: environments on an older platform blueprint don't pass it.
  default = null

  validation {
    condition     = var.cni != "cilium" || var.cilium_chart_version != null
    error_message = "cilium_chart_version is required when cni is cilium."
  }
}

variable "cilium_repair" {
  description = "Force reinstall Cilium, even if a Ryvn installation has adopted it."
  type        = bool
  default     = false
}

variable "cilium_restart_pods_blocked_by_disruption_budgets" {
  description = "When moving nodes to Cilium, delete pods whose PodDisruptionBudgets never allow evicting them instead of failing the apply. This bypasses those budgets and takes the workloads down; use it only for a move agreed with the customer."
  type        = bool
  default     = false
}

variable "enable_transit_gateway_subnets" {
  description = "Enable creation of Transit Gateway subnets. When enabled, creates /28 subnets (14 usable IPs each) following AWS best practices."
  type        = bool
  default     = false
}

variable "transit_gateway_subnets" {
  description = "Custom CIDR blocks for transit gateway subnets. If empty, will auto-calculate /28 subnets when enable_transit_gateway_subnets is true. AWS recommends /28 subnets to minimize IP usage."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.transit_gateway_subnets :
      can(cidrhost(cidr, 0)) && tonumber(split("/", cidr)[1]) >= 28
    ])
    error_message = "Transit Gateway subnets should use /28 or smaller CIDR blocks (e.g., /28, /29, /30) as recommended by AWS best practices to conserve IP addresses."
  }
}

variable "cluster_access_entries" {
  description = <<-EOT
    Map of additional cluster access entries to create. Will be merged with default Ryvn maintenance access.
    Example:
    cluster_access_entries = {
      developer_access = {
        kubernetes_groups = []
        principal_arn     = "arn:aws:iam::123456789012:role/DeveloperRole"
        type             = "STANDARD"

        policy_associations = {
          cluster_view = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    }
  EOT
  type        = any
  default     = {}
}

variable "cluster_autoscaler" {
  description = "Cluster Autoscaler configuration. Set enabled = true to create IAM role and policy."
  type = object({
    enabled = optional(bool, false)
  })
  default = {
    enabled = false
  }
}

variable "pod_identity_associations" {
  description = <<-EOT
    Map of additional EKS Pod Identity associations to create. Assumes IAM roles already exist.
    Cannot create associations in system-managed namespaces: ryvn-system, cert-manager, external-dns, kube-system.
    Example:
    pod_identity_associations = {
      my_app = {
        namespace       = "default"
        service_account = "my-app-sa"
        role_arn        = "arn:aws:iam::123456789012:role/MyAppRole"
      }
    }
  EOT
  type = map(object({
    namespace       = string
    service_account = string
    role_arn        = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.pod_identity_associations :
      !contains(["ryvn-system", "cert-manager", "external-dns", "kube-system"], v.namespace)
    ])
    error_message = "Cannot create pod identity associations in system-managed namespaces: ryvn-system, cert-manager, external-dns, kube-system."
  }
}

variable "iam_permissions_boundary_arn" {
  description = <<-EOT
    ARN of an IAM policy to attach as the permissions boundary on every IAM role Ryvn
    creates. Set this in accounts whose guardrails deny iam:CreateRole for roles that do
    not carry a specific boundary. The boundary also caps what the resulting roles can
    do, so it must permit the actions each cluster component needs. Null attaches no
    boundary.
  EOT
  type        = string
  default     = null
}

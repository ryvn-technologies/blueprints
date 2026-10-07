variable "location" {
  type        = string
  description = "The location to launch the cluster in"
}

# Records in this zone resolve only inside the VNet, so an ACME HTTP-01 or
# DNS-01 challenge cannot be validated against it: TLS on an internal load
# balancer needs a name under public_root_domain.
variable "internal_root_domain" {
  type        = string
  description = "The internal root domain."
}

variable "public_root_domain" {
  type        = string
  description = "The public root domain."
}

variable "cluster_version" {
  type        = string
  description = "The Kubernetes version to use for the AKS cluster."
  default     = "1.34"
}

variable "node_os_channel_upgrade" {
  type        = string
  default     = "NodeImage"
  nullable    = true
  description = "Upgrade channel for the node OS image: None, Unmanaged, SecurityPatch or NodeImage. Upgrades on the NodeImage and SecurityPatch channels run inside maintenance_window_node_os."

  validation {
    condition     = var.node_os_channel_upgrade == null || contains(["None", "Unmanaged", "SecurityPatch", "NodeImage"], var.node_os_channel_upgrade)
    error_message = "node_os_channel_upgrade must be one of None, Unmanaged, SecurityPatch or NodeImage."
  }
}

variable "maintenance_window_node_os" {
  type = object({
    frequency    = string
    interval     = number
    duration     = number
    day_of_week  = optional(string)
    day_of_month = optional(number)
    week_index   = optional(string)
    start_time   = optional(string)
    utc_offset   = optional(string)
    start_date   = optional(string)
    not_allowed = optional(set(object({
      start = string
      end   = string
    })))
  })
  default = {
    frequency   = "Weekly"
    interval    = 1
    duration    = 8
    day_of_week = "Sunday"
    start_time  = "00:00"
    utc_offset  = "+00:00"
  }
  nullable    = true
  description = "AKS planned maintenance schedule (aksManagedNodeOSUpgradeSchedule) for node OS image upgrades. frequency is Daily, Weekly, AbsoluteMonthly or RelativeMonthly; duration is in hours (4-24); start_time is HH:mm in the utc_offset timezone; not_allowed takes RFC3339 start/end pairs. Defaults to Sundays 00:00-08:00 UTC. Set to null to let Azure upgrade at any time."

  validation {
    condition     = var.maintenance_window_node_os == null || contains(["Daily", "Weekly", "AbsoluteMonthly", "RelativeMonthly"], try(var.maintenance_window_node_os.frequency, ""))
    error_message = "maintenance_window_node_os.frequency must be one of Daily, Weekly, AbsoluteMonthly or RelativeMonthly."
  }

  validation {
    condition     = var.maintenance_window_node_os == null || (try(var.maintenance_window_node_os.duration, 0) >= 4 && try(var.maintenance_window_node_os.duration, 0) <= 24)
    error_message = "maintenance_window_node_os.duration must be between 4 and 24 hours."
  }
}

variable "maintenance_window_auto_upgrade" {
  type = object({
    frequency    = string
    interval     = number
    duration     = number
    day_of_week  = optional(string)
    day_of_month = optional(number)
    week_index   = optional(string)
    start_time   = optional(string)
    utc_offset   = optional(string)
    start_date   = optional(string)
    not_allowed = optional(set(object({
      start = string
      end   = string
    })))
  })
  default = {
    frequency   = "Weekly"
    interval    = 1
    duration    = 8
    day_of_week = "Sunday"
    start_time  = "00:00"
    utc_offset  = "+00:00"
  }
  nullable    = true
  description = "AKS planned maintenance schedule (aksManagedAutoUpgradeSchedule) for Kubernetes patch auto-upgrades. frequency is Weekly, AbsoluteMonthly or RelativeMonthly; duration is in hours (4-24); start_time is HH:mm in the utc_offset timezone; not_allowed takes RFC3339 start/end pairs. Defaults to Sundays 00:00-08:00 UTC. Set to null to let Azure upgrade at any time."

  validation {
    condition     = var.maintenance_window_auto_upgrade == null || contains(["Weekly", "AbsoluteMonthly", "RelativeMonthly"], try(var.maintenance_window_auto_upgrade.frequency, ""))
    error_message = "maintenance_window_auto_upgrade.frequency must be one of Weekly, AbsoluteMonthly or RelativeMonthly."
  }

  validation {
    condition     = var.maintenance_window_auto_upgrade == null || (try(var.maintenance_window_auto_upgrade.duration, 0) >= 4 && try(var.maintenance_window_auto_upgrade.duration, 0) <= 24)
    error_message = "maintenance_window_auto_upgrade.duration must be between 4 and 24 hours."
  }
}

variable "environment_name" {
  type        = string
  description = "The environment name (e.g., dev, staging, prod)"
  default     = "dev"
}

variable "cluster_bootstrap_perms" {
  type        = bool
  default     = false
  description = "If true, grants cluster admin permissions to the terraform executor for initial setup. Should be disabled after bootstrap."
}

variable "cost_analysis_enabled" {
  type        = bool
  default     = true
  description = "Enable the AKS cost analysis add-on to surface Kubernetes namespace-level cost breakdowns in Azure Cost Management. Requires sku_tier Standard or Premium."
}

variable "key_vault_secrets_provider_enabled" {
  type        = bool
  default     = true
  description = "Enable the Azure Key Vault Provider for Secrets Store CSI Driver add-on, letting workloads mount Key Vault secrets as CSI volumes. Installs the CSI driver and Azure provider on the cluster and creates an addon-owned managed identity in the node resource group. Does not create or modify any Key Vault. Secret rotation is left at the module defaults (disabled, 2m poll)."
}

variable "control_plane_log_retention_days" {
  type        = number
  default     = 30
  nullable    = false
  description = "Days to retain AKS control-plane and full audit logs in Log Analytics. Must be a whole number from 30 to 730."

  validation {
    condition = (
      var.control_plane_log_retention_days >= 30 &&
      var.control_plane_log_retention_days <= 730
    )
    error_message = "control_plane_log_retention_days must be between 30 and 730."
  }

  validation {
    condition     = floor(var.control_plane_log_retention_days) == var.control_plane_log_retention_days
    error_message = "control_plane_log_retention_days must be a whole number."
  }
}

variable "aks_node_pools" {
  description = "Map of AKS node pool definitions to create. Values will be merged with defaults if not specified."
  type = map(object({
    vm_size         = optional(string)
    min_count       = optional(number)
    max_count       = optional(number)
    node_count      = optional(number)
    os_disk_size_gb = optional(number)
    os_sku          = optional(string) # Ubuntu (default), AzureLinux, Windows2019, Windows2022
    labels          = optional(map(string))
    taints          = optional(list(string)) # Only supported on non-system pools
    upgrade_settings = optional(object({
      max_surge                     = optional(string)
      max_unavailable               = optional(string)
      drain_timeout_in_minutes      = optional(number)
      node_soak_duration_in_minutes = optional(number)
      undrainable_node_behavior     = optional(string)
    }))
  }))
  default = {}

  validation {
    condition     = try(var.aks_node_pools.system.upgrade_settings, null) == null
    error_message = "aks_node_pools.system.upgrade_settings is not supported; upgrade_settings only applies to additional pools."
  }

  validation {
    condition = alltrue([
      for name, pool in var.aks_node_pools : pool.upgrade_settings == null ? true : (
        (pool.upgrade_settings.max_surge != null) != (pool.upgrade_settings.max_unavailable != null) &&
        alltrue([
          for strategy in [pool.upgrade_settings.max_surge, pool.upgrade_settings.max_unavailable] :
          strategy == null ? true : trimspace(strategy) != ""
        ])
      ) if name != "system"
    ])
    error_message = "Each explicit aks_node_pools upgrade_settings block must set exactly one nonempty max_surge or max_unavailable; leave the other null or omitted."
  }
}

# Network configuration
variable "vnet_cidr" {
  description = "CIDR block for subnet allocation. When creating a new VNet, this is the VNet's address space. When using an existing VNet (existing_vnet_id), this is the range within that VNet reserved for Ryvn subnets. Recommended: /16 for large clusters, /20 for medium, /23 minimum for small clusters with overlay mode."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vnet_cidr, 0))
    error_message = "vnet_cidr must be a valid CIDR block (e.g., 10.0.0.0/16)."
  }

  validation {
    condition     = tonumber(split("/", var.vnet_cidr)[1]) <= 24
    error_message = "VNet must be /24 or larger. Smaller VNets cannot support AKS clusters. Minimum recommended: /23 with overlay mode."
  }
}

variable "network_plugin_mode" {
  description = "Azure CNI mode: 'flat' (default, pods use VNet IPs) or 'overlay' (pods use separate pod CIDR, more IP-efficient). Note: Changing this on an existing cluster requires cluster recreation."
  type        = string
  default     = "overlay"
  validation {
    condition     = contains(["flat", "overlay"], var.network_plugin_mode)
    error_message = "network_plugin_mode must be either 'flat' or 'overlay'."
  }
}

variable "pod_cidr" {
  description = "CIDR range for pod IP addresses when using CNI Overlay mode. Must not overlap with VNet or service CIDR. Only used when network_plugin_mode='overlay'. Recommended: use a /16 (e.g., 192.168.0.0/16)."
  type        = string
  default     = "192.168.0.0/16"
}

variable "ebpf_data_plane" {
  description = "Set to 'cilium' to enable Azure CNI Powered by Cilium."
  type        = string
  default     = null

  validation {
    condition     = var.ebpf_data_plane == null || var.ebpf_data_plane == "cilium"
    error_message = "ebpf_data_plane must be null or 'cilium'."
  }

  validation {
    condition     = var.ebpf_data_plane != "cilium" || var.network_plugin_mode == "overlay"
    error_message = "ebpf_data_plane = 'cilium' requires network_plugin_mode to be 'overlay'."
  }

  validation {
    condition = var.ebpf_data_plane != "cilium" || alltrue([
      for pool in values(var.aks_node_pools) :
      !startswith(lower(coalesce(pool.os_sku, "Ubuntu")), "windows")
    ])
    error_message = "ebpf_data_plane 'cilium' supports Linux node pools only."
  }
}

variable "ryvn_system_namespace" {
  type        = string
  default     = "ryvn-system"
  description = "Ryvn system namespace"
}

variable "zones" {
  description = "List of availability zones for AKS node pools. If null, uses all zones available in the region. Example: [\"1\", \"3\"]"
  type        = list(string)
  default     = null
}

variable "tags" {
  description = "Custom tags to apply to all resources. Merged with Ryvn's default tags (Environment, Terraform, Cluster)."
  type        = map(string)
  default     = {}
}

variable "existing_vnet_id" {
  description = "Resource ID of an existing VNet to deploy into. When set, Ryvn creates subnets inside this VNet instead of creating a new one. The VNet must be in the same region as the deployment."
  type        = string
  default     = null

  validation {
    condition     = var.existing_vnet_id == null || can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.Network/virtualNetworks/.+$", var.existing_vnet_id))
    error_message = "existing_vnet_id must be null or a valid Azure VNet resource ID (e.g., /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>)."
  }
}

variable "existing_route_table_id" {
  description = "Resource ID of an existing route table to associate with the AKS node pool subnets. When set, the cluster is configured with outbound_type=userDefinedRouting and the AKS-managed outbound public IP is removed. The route table must contain a default route (0.0.0.0/0) to a network virtual appliance (e.g. a firewall) and that appliance must permit AKS-required outbound FQDNs (https://learn.microsoft.com/en-us/azure/aks/limit-egress-traffic)."
  type        = string
  default     = null

  validation {
    condition     = var.existing_route_table_id == null || can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.Network/routeTables/.+$", var.existing_route_table_id))
    error_message = "existing_route_table_id must be null or a valid Azure Route Table resource ID (e.g., /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/routeTables/<name>)."
  }
}

# ============================================================================
# Default-deny cloud egress firewall
# ============================================================================

variable "egress_firewall" {
  description = "Managed default-deny egress firewall. Omitted/disabled preserves prior behavior. When enabled, an Azure Firewall inspects all node-pool and external attachment subnet egress; only reviewed platform baseline destinations, the selected customer policy's exact/wildcard domains (HTTPS via visible TLS SNI, HTTP via Host) and narrow IPv4 network exceptions are permitted."
  type = object({
    enabled            = optional(bool, false)
    default_action     = optional(string, "deny")
    cluster_policy_key = optional(string, "cluster")
    tier               = optional(string, "Standard")
    log_retention_days = optional(number, 30)
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
  default = {}

  validation {
    condition     = !var.egress_firewall.enabled || var.egress_firewall.default_action == "deny"
    error_message = "egress_firewall.default_action must be \"deny\"; v1 has no permit-rest mode."
  }

  validation {
    condition     = !var.egress_firewall.enabled || contains(keys(var.egress_firewall.policies), var.egress_firewall.cluster_policy_key)
    error_message = "egress_firewall.cluster_policy_key must name an existing entry in egress_firewall.policies."
  }

  validation {
    condition     = contains(["Standard", "Premium"], var.egress_firewall.tier)
    error_message = "egress_firewall.tier must be \"Standard\" or \"Premium\"."
  }

  validation {
    condition     = var.egress_firewall.log_retention_days >= 30 && var.egress_firewall.log_retention_days <= 730
    error_message = "egress_firewall.log_retention_days must be between 30 and 730."
  }

  validation {
    condition     = !var.egress_firewall.enabled || var.existing_vnet_id == null
    error_message = "egress_firewall cannot be enabled together with existing_vnet_id; the existing-VNet protected combination is not yet designed."
  }

  validation {
    condition     = !var.egress_firewall.enabled || var.existing_route_table_id == null
    error_message = "egress_firewall cannot be enabled together with existing_route_table_id; the managed firewall owns the node-pool route table."
  }

  validation {
    condition     = !var.egress_firewall.enabled || tonumber(split("/", var.vnet_cidr)[1]) <= 21
    error_message = "egress_firewall requires vnet_cidr of /21 or larger so that AzureFirewallSubnet (allocator slot 4) is at least /26."
  }

  validation {
    condition = alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for rule in values(policy.domain_allow) : (
          contains(["http", "https"], rule.protocol) &&
          length(rule.domains) > 0 &&
          (rule.destination_ports == null || (length(rule.destination_ports) == 1 && contains(rule.destination_ports, rule.protocol == "http" ? 80 : 443)))
        )
      ]
    ]))
    error_message = "egress_firewall domain_allow entries need nonempty domains, protocol http or https, and if destination_ports is set, exactly [80] for http or [443] for https."
  }

  validation {
    condition = alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for domain in flatten([for rule in values(policy.domain_allow) : tolist(rule.domains)]) : (
          length(domain) <= 253 &&
          domain == lower(domain) &&
          can(regex("^(\\*\\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", domain)) &&
          !can(regex("^(\\*\\.)?[0-9]+(\\.[0-9]+){3}$", domain))
        )
      ]
    ]))
    error_message = "egress_firewall domain patterns must be lowercase canonical DNS names, exact (example.com) or leading-wildcard (*.example.com): no bare *, leading dot, partial/internal wildcards, IP literals, URLs, paths, ports, trailing dots or invalid labels."
  }

  validation {
    condition = alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for domain in flatten([for rule in values(policy.domain_allow) : tolist(rule.domains)]) : (
          length(split(".", trimprefix(domain, "*."))) >= 2 &&
          !contains(local.egress_public_suffixes, trimprefix(domain, "*.")) &&
          !(contains(local.egress_public_suffixes, "*.${join(".", slice(split(".", trimprefix(domain, "*.")), 1, length(split(".", trimprefix(domain, "*.")))))}") &&
          !contains(local.egress_public_suffixes, "!${trimprefix(domain, "*.")}"))
        )
      ]
    ]))
    error_message = "egress_firewall domain patterns must not be a bare public suffix or a wildcard over a public suffix (e.g. *.com, *.co.uk, *.azurewebsites.net)."
  }

  validation {
    condition = alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for rule in values(policy.network_allow) : (
          contains(["tcp", "udp"], rule.protocol) &&
          length(rule.destination_ports) > 0 &&
          alltrue([for port in rule.destination_ports : port == floor(port) && port >= 1 && port <= 65535]) &&
          length(trimspace(rule.reason)) > 0 &&
          length(rule.destination_ipv4_cidrs) > 0
        )
      ]
    ]))
    error_message = "egress_firewall network_allow entries require protocol tcp|udp, nonempty explicit integer destination_ports 1-65535, nonempty destination_ipv4_cidrs and a nonempty reason."
  }

  validation {
    condition = alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for rule in values(policy.network_allow) : !(rule.protocol == "udp" && contains(rule.destination_ports, 443))
      ]
    ]))
    error_message = "egress_firewall network_allow must not open UDP/443; the QUIC block is part of the v1 contract."
  }

  validation {
    condition = !var.egress_firewall.enabled || alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for rule in values(policy.network_allow) : [
          for cidr in rule.destination_ipv4_cidrs : (
            can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+$", cidr)) &&
            can(cidrnetmask(cidr)) &&
            try(cidrsubnet(cidr, 0, 0) == cidr, false) &&
            try(tonumber(split("/", cidr)[1]) >= 8, false) &&
            try(alltrue([
              for reserved in local.egress_rejected_destination_cidrs :
              cidrsubnet("${cidrhost(cidr, 0)}/${min(tonumber(split("/", cidr)[1]), tonumber(split("/", reserved)[1]))}", 0, 0) !=
              cidrsubnet("${cidrhost(reserved, 0)}/${min(tonumber(split("/", cidr)[1]), tonumber(split("/", reserved)[1]))}", 0, 0)
            ]), false)
          )
        ]
      ]
    ]))
    error_message = "egress_firewall network_allow destination_ipv4_cidrs must be normalized public IPv4 CIDRs (/8 or smaller): no IPv6, 0.0.0.0/0, multicast, reserved, link-local, RFC1918 or VNet/pod/service ranges."
  }
}

variable "platform_https_domains" {
  description = "Additional exact HTTPS/443 hostnames for cluster platform sources only; added to the AKS and registry baseline. Ignored when the firewall is disabled."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([for domain in var.platform_https_domains : (
      length(domain) <= 253 &&
      domain == lower(domain) &&
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", domain))
    )])
    error_message = "platform_https_domains requires exact lowercase multi-label DNS hostnames without wildcards, URL schemes, ports, paths or trailing dots."
  }
}

variable "additional_subnet_groups" {
  description = "Ordered append-only allocation of external compute subnets, independent of the firewall. Retired entries keep their range reserved after their subnet is removed; see the teardown runbook."
  type = list(object({
    name               = string
    ipv4_prefix_length = number
    retired            = optional(bool, false)
  }))
  default = []

  validation {
    condition     = length(var.additional_subnet_groups) == 0 || var.existing_vnet_id == null
    error_message = "additional_subnet_groups requires the root-owned VNet; allocation cannot be proven inside an existing VNet."
  }

  validation {
    condition = length(distinct([for group in var.additional_subnet_groups : group.name])) == length(var.additional_subnet_groups) && alltrue([
      for group in var.additional_subnet_groups : group.name != "cluster" && can(regex("^[a-z][a-z0-9_]{0,30}$", group.name))
    ])
    error_message = "additional_subnet_groups names must be unique, match ^[a-z][a-z0-9_]{0,30}$ and not be cluster."
  }
}

variable "egress_attachments" {
  description = "External class to already allocated subnet group and customer policy. No subnet is created by an attachment."
  type = map(object({
    subnet_group_key = string
    policy_key       = string
  }))
  default = {}

  validation {
    condition     = length(var.egress_attachments) == 0 || var.egress_firewall.enabled
    error_message = "egress_attachments requires egress_firewall.enabled = true."
  }

  validation {
    condition     = !contains(keys(var.egress_attachments), "cluster")
    error_message = "egress_attachments must not use the reserved attachment name \"cluster\"."
  }

  validation {
    condition     = alltrue([for key in keys(var.egress_attachments) : can(regex("^[a-z][a-z0-9_]{0,30}$", key))])
    error_message = "egress_attachments keys must match ^[a-z][a-z0-9_]{0,30}$."
  }

  validation {
    condition     = alltrue([for attachment in values(var.egress_attachments) : contains(keys(var.egress_firewall.policies), attachment.policy_key)])
    error_message = "egress_attachments[*].policy_key must name an existing egress_firewall.policies entry."
  }

  validation {
    condition = alltrue([for attachment in values(var.egress_attachments) :
      contains([for group in var.additional_subnet_groups : group.name if !group.retired], attachment.subnet_group_key)
    ])
    error_message = "egress_attachments[*].subnet_group_key must name an active additional_subnet_groups entry."
  }

  validation {
    condition     = length(distinct([for attachment in values(var.egress_attachments) : attachment.subnet_group_key])) == length(var.egress_attachments)
    error_message = "Only one egress_attachments entry may claim each subnet group."
  }
}

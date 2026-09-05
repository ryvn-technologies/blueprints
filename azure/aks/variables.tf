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
  }))
  default = {}
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


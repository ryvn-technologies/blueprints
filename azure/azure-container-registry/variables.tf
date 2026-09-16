variable "location" {
  description = "Azure region for the container registry"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group in which the registry and its identities are created"
  type        = string
}

variable "environment" {
  description = "Ryvn environment name this registry belongs to"
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for the registry name when registry_name is not set"
  type        = string
  default     = "registry"
}

variable "registry_name" {
  description = "Base name for the registry. Non-alphanumeric characters are stripped and a random suffix is appended to keep it globally unique. Falls back to name_prefix when empty."
  type        = string
  default     = ""
}

variable "sku" {
  description = "ACR SKU: Basic, Standard or Premium"
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be one of Basic, Standard, Premium."
  }
}

variable "public_network_access_enabled" {
  description = "Allow access from public networks. Disabling requires the Premium SKU and private endpoints."
  type        = bool
  default     = true
}

variable "zone_redundancy_enabled" {
  description = "Enable zone redundancy (Premium SKU only)"
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "AKS cluster whose kubelet identity should receive pull access and whose OIDC issuer federates the copier. Leave empty for attached clusters and set node_principal_ids and oidc_issuer_url explicitly instead."
  type        = string
  default     = ""
}

variable "cluster_resource_group_name" {
  description = "Resource group of the AKS cluster named in cluster_name. Defaults to resource_group_name."
  type        = string
  default     = ""
}

variable "node_principal_ids" {
  description = "Explicit object ids of the kubelet (node) identities that must be able to pull. Merged with the kubelet identity detected from the AKS cluster; required for attached clusters."
  type        = list(string)
  default     = []
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster used to federate the copier's service account. Overrides cluster detection; required for attached clusters."
  type        = string
  default     = ""
}

variable "require_node_pull_grant" {
  description = "Fail provisioning when no kubelet identity could be resolved for pull access"
  type        = bool
  default     = true
}

variable "push_namespace" {
  description = "Kubernetes namespace in which the artifact copier runs"
  type        = string
}

variable "push_service_accounts" {
  description = "Kubernetes service accounts (in push_namespace) that run the artifact copier and receive push access via Workload Identity"
  type        = list(string)

  validation {
    condition     = length(var.push_service_accounts) > 0
    error_message = "push_service_accounts must contain at least one service account."
  }
}

variable "tags" {
  description = "Additional tags applied to all resources"
  type        = map(string)
  default     = {}
}

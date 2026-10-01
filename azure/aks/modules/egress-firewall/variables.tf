variable "name_prefix" {
  type        = string
  description = "Environment name used to derive resource names."
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "zones" {
  type    = list(string)
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "firewall_subnet_id" {
  type        = string
  description = "ID of the AzureFirewallSubnet (>= /26) the firewall is deployed into."
}

variable "tier" {
  type        = string
  description = "Standard or Premium. Premium never enables TLS inspection or IDPS implicitly."
  validation {
    condition     = contains(["Standard", "Premium"], var.tier)
    error_message = "tier must be Standard or Premium."
  }
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "policies" {
  description = "Customer destination policies keyed by policy name (validated by the root module)."
  type = map(object({
    domain_allow = map(object({
      domains           = set(string)
      protocol          = string
      destination_ports = optional(set(number))
    }))
    network_allow = map(object({
      destination_ipv4_cidrs = set(string)
      protocol               = string
      destination_ports      = set(number)
      reason                 = string
    }))
  }))
}

variable "classes" {
  description = "Attachment classes: reserved `cluster` plus external attachments. Sources are non-overlapping IPv4 CIDRs."
  type = map(object({
    kind       = string # cluster | external
    policy_key = string
    sources    = list(string)
  }))

  validation {
    condition     = alltrue([for class in values(var.classes) : contains(["cluster", "external"], class.kind)])
    error_message = "class kind must be cluster or external."
  }
}

variable "platform_https_domains" {
  type        = set(string)
  description = "Additional exact HTTPS/443 hostnames for cluster platform sources."
}

variable "aks_region" {
  type = string
}

variable "azure_policy_enabled" {
  type    = bool
  default = true
}

variable "key_vault_secrets_provider_enabled" {
  type    = bool
  default = true
}

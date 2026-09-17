variable "location" {
  description = "Azure region for the managed identities"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the managed identities and federated credentials"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster (oidcIssuerProfile.issuerUrl)"
  type        = string

  validation {
    condition     = startswith(var.oidc_issuer_url, "https://")
    error_message = "oidc_issuer_url must be an https:// URL."
  }
}

variable "name_prefix" {
  description = "Prefix for managed identity and federated credential names, typically the Ryvn environment name"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. production, staging), applied as a tag"
  type        = string
}

variable "role_groups" {
  description = <<-EOT
    Named groups of workloads that share one managed identity. Each group lists
    the Kubernetes subjects that may become the identity (associations) and the
    role assignments given to it (role_assignments, keyed by a stable name of
    your choosing). Each assignment is a role definition at a scope, exactly
    the arguments of azurerm_role_assignment. Resource modules expose the scope
    and role they grant access with as outputs (for example the bucket
    module's role_assignment_scope and role_definition_name).
  EOT
  type = map(object({
    role_name = optional(string)
    associations = map(object({
      namespace       = string
      service_account = string
    }))
    role_assignments = optional(map(object({
      scope                = string
      role_definition_name = string
    })), {})
  }))

  validation {
    condition     = alltrue([for group in var.role_groups : length(group.associations) > 0])
    error_message = "Each role group must list at least one association."
  }

  validation {
    condition = alltrue(flatten([
      for group in var.role_groups : [
        for assoc in group.associations :
        trimspace(assoc.namespace) != "" && trimspace(assoc.service_account) != ""
      ]
    ]))
    error_message = "Every association needs a non-empty namespace and service_account."
  }

  validation {
    condition = length(distinct(flatten([
      for group in var.role_groups : [
        for assoc in group.associations : "${assoc.namespace}/${assoc.service_account}"
      ]
    ]))) == sum([for group in var.role_groups : length(group.associations)])
    error_message = "Each namespace/service_account pair may appear in only one association across all role groups. A ServiceAccount can be annotated with only one managed identity client ID."
  }

  validation {
    condition = alltrue([
      for group in var.role_groups :
      length(group.associations) <= 20
    ])
    error_message = "Azure allows at most 20 federated credentials per managed identity. Split the group."
  }

  validation {
    condition = alltrue([
      for group in var.role_groups :
      length(distinct([for a in values(group.role_assignments) : lower("${a.scope}|${a.role_definition_name}")])) == length(group.role_assignments)
    ])
    error_message = "role_assignments must be distinct (scope, role_definition_name) pairs within a role group: Azure holds one assignment per principal/scope/role, so two keys for the same pair would fight over it."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

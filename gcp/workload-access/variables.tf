variable "project_id" {
  description = "GCP project that owns the GKE cluster and the granted resources"
  type        = string
}

variable "project_number" {
  description = "Numeric project number used in the Workload Identity principal. Leave empty to resolve it from project_id, which requires resourcemanager.projects.get."
  type        = string
  default     = ""
}

variable "region" {
  description = "Default region for the google provider. No regional resources are created."
  type        = string
  default     = "us-central1"
}

# Subjects
variable "namespace" {
  description = "Kubernetes namespace of the ServiceAccounts that receive the grants"
  type        = string

  validation {
    condition     = trimspace(var.namespace) != ""
    error_message = "namespace must not be empty."
  }
}

variable "service_accounts" {
  description = "Kubernetes ServiceAccount names in namespace that receive the grants. Ryvn's charts name the ServiceAccount after the installation, so these are installation names."
  type        = list(string)

  validation {
    condition     = length([for service_account in var.service_accounts : service_account if trimspace(service_account) != ""]) > 0
    error_message = "service_accounts must contain at least one non-empty name."
  }
}

variable "include_pre_deploy" {
  description = "Also grant the <name>-pre-deploy ServiceAccount used by Ryvn's pre-deploy hook Job for each entry in service_accounts."
  type        = bool
  default     = true
}

# Grants
variable "grants" {
  description = <<-EOT
    What the subjects may access. Pass resource modules' workload_grants output
    through unchanged (the bucket blueprint exposes it as workloadGrants). Each
    grant binds role on the target resource of the given kind. Only
    kind = "bucket" (target = bucket name) is supported today.
  EOT
  type = list(object({
    kind   = string
    target = string
    role   = string
  }))

  validation {
    condition     = length(var.grants) > 0
    error_message = "grants must contain at least one entry."
  }

  validation {
    condition     = alltrue([for grant in var.grants : grant.kind == "bucket"])
    error_message = "grant.kind must be \"bucket\"."
  }

  validation {
    condition     = alltrue([for grant in var.grants : trimspace(grant.target) != "" && startswith(grant.role, "roles/")])
    error_message = "Each grant needs a non-empty target and a role of the form roles/<name>."
  }
}

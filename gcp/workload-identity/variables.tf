variable "project_id" {
  description = "GCP project that owns the GKE cluster and the granted buckets"
  type        = string
}

variable "project_number" {
  description = "Numeric project number. Leave empty to resolve it from project_id, which requires resourcemanager.projects.get."
  type        = string
  default     = ""
}

variable "region" {
  description = "Default region for the google provider. No regional resources are created."
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  description = "Accepted for interface parity with the AWS and Azure modules. GCP creates no named identity resources."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Accepted for interface parity with the AWS and Azure modules. GCP creates no labelled resources."
  type        = string
  default     = ""
}

variable "role_groups" {
  description = <<-EOT
    Named groups of workloads that share the same IAM bindings. Each group
    lists the Kubernetes subjects (associations) and the bindings they receive:
    buckets binds role on the named bucket; project_roles binds role on the
    project, optionally narrowed by an IAM condition to specific resources, as
    Cloud SQL and Memorystore require. Both are keyed by a stable name of your
    choosing. Resource modules expose the values as outputs (for example the
    bucket module's bucket_name and iam_role). The ServiceAccount is itself
    the principal, so no identity resource is created; the group only scopes
    which subjects receive which bindings.
  EOT
  type = map(object({
    role_name = optional(string)
    associations = map(object({
      namespace       = string
      service_account = string
    }))
    buckets = optional(map(object({
      name = string
      role = string
    })), {})
    project_roles = optional(map(object({
      role = string
      condition = optional(object({
        title       = string
        expression  = string
        description = optional(string)
      }))
    })), {})
  }))

  validation {
    condition = alltrue(flatten([
      for group in var.role_groups : [
        for bucket in group.buckets : trimspace(bucket.name) != ""
      ]
    ]))
    error_message = "Every bucket binding needs a non-empty bucket name."
  }

  validation {
    condition = alltrue([
      for group in var.role_groups :
      length(distinct([for b in values(group.buckets) : "${b.name}|${b.role}"])) == length(group.buckets)
      && length(distinct([for p in values(group.project_roles) : jsonencode(p.condition == null ? [p.role] : [p.role, p.condition.title, p.condition.expression, p.condition.description == null ? "" : p.condition.description])])) == length(group.project_roles)
    ])
    error_message = "Bindings must be distinct within a role group: one (bucket, role) per key in buckets and one (role, condition) per key in project_roles. IAM holds a single member binding per pair, so two keys for one pair would fight over it."
  }

  validation {
    condition = alltrue(flatten([
      for group in var.role_groups : [
        for binding in concat(values(group.buckets), values(group.project_roles)) :
        can(regex("^(roles|projects|organizations)/", binding.role))
      ]
    ]))
    error_message = "Every role must be a predefined role (roles/...) or a custom role (projects/.../roles/... or organizations/.../roles/...)."
  }

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
    error_message = "Each namespace/service_account pair may appear in only one association across all role groups. A ServiceAccount belongs to exactly one group so its bindings have a single owner."
  }
}

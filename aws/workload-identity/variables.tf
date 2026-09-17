variable "aws_region" {
  description = "AWS region of the EKS cluster"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for IAM role names, typically the Ryvn environment name"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. production, staging), applied as a tag"
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster that receives the Pod Identity associations"
  type        = string
}

variable "role_groups" {
  description = <<-EOT
    Named groups of workloads that share one IAM role. Each group lists the
    Kubernetes subjects that may assume the role (associations) and the
    managed policies attached to it (policy_arns, keyed by a stable name of
    your choosing). Resource modules expose their policy ARNs as outputs (for
    example the bucket module's policy_arn); pass those in directly. This
    module never writes resource-side permissions.
  EOT
  type = map(object({
    role_name = optional(string)
    associations = map(object({
      namespace       = string
      service_account = string
    }))
    policy_arns = optional(map(string), {})
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
    error_message = "Each namespace/service_account pair may appear in only one association across all role groups. EKS allows one Pod Identity association per ServiceAccount per cluster."
  }

  validation {
    condition = alltrue([
      for group in var.role_groups :
      length(distinct(values(group.policy_arns))) == length(group.policy_arns)
    ])
    error_message = "policy_arns values must be distinct within a role group: an attachment is identified by (role, policy ARN), so two keys for one ARN would fight over the same attachment."
  }

  validation {
    condition     = alltrue([for group in var.role_groups : length(group.policy_arns) <= 20])
    error_message = "A role can carry at most 20 attached managed policies. The AWS default quota is 10; request an increase before exceeding it."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

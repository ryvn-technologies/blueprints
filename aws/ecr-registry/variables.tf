variable "aws_region" {
  description = "AWS region that hosts the ECR registry"
  type        = string
}

variable "environment" {
  description = "Ryvn environment name this registry belongs to"
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for the repository namespace when registry_name is not set"
  type        = string
  default     = "registry"
}

variable "registry_name" {
  description = "Base name for the ECR repository namespace. A random suffix is appended to keep it unique. Falls back to name_prefix when empty."
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "EKS cluster that runs the artifact copier and whose managed node groups should receive pull access. Leave empty for attached clusters and set node_role_names explicitly instead."
  type        = string
  default     = ""
}

variable "node_role_names" {
  description = "Explicit IAM role names used by cluster nodes (kubelet) that must be able to pull. Merged with roles detected from EKS managed node groups; required for attached clusters and for Karpenter-managed nodes."
  type        = list(string)
  default     = []
}

variable "require_node_pull_grant" {
  description = "Fail provisioning when no node IAM role could be resolved for pull access"
  type        = bool
  default     = true
}

variable "push_namespace" {
  description = "Kubernetes namespace in which the artifact copier runs"
  type        = string
}

variable "push_service_accounts" {
  description = "Kubernetes service accounts (in push_namespace) that run the artifact copier and receive push access via EKS Pod Identity"
  type        = list(string)

  validation {
    condition     = length(var.push_service_accounts) > 0
    error_message = "push_service_accounts must contain at least one service account."
  }
}

variable "hub_principal_arn" {
  description = "ARN of the Ryvn hub principal allowed to assume a read-only role for this registry. When empty no hub role is created and the registry is exposed with clusterDefault credentials."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags applied to all resources"
  type        = map(string)
  default     = {}
}

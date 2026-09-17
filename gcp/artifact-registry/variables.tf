variable "project_id" {
  description = "GCP project that owns the Artifact Registry repository"
  type        = string
}

variable "region" {
  description = "Artifact Registry location (e.g. us-central1). Determines the registry endpoint <region>-docker.pkg.dev."
  type        = string
}

variable "environment" {
  description = "Ryvn environment name this registry belongs to"
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for the repository id when registry_name is not set"
  type        = string
  default     = "registry"
}

variable "registry_name" {
  description = "Base name for the repository. A random suffix is appended to keep it unique. Falls back to name_prefix when empty."
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "GKE cluster whose node pools should receive pull access. Leave empty for attached clusters and set node_service_accounts explicitly instead."
  type        = string
  default     = ""
}

variable "cluster_location" {
  description = "Location of the GKE cluster named in cluster_name. Defaults to region."
  type        = string
  default     = ""
}

variable "node_service_accounts" {
  description = "Explicit node/kubelet service account emails that must be able to pull. Merged with accounts detected from the GKE cluster; required for attached clusters."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "require_node_pull_grant" {
  description = "Fail provisioning when no node identity could be resolved for pull access"
  type        = bool
  default     = true
}

variable "push_namespace" {
  description = "Kubernetes namespace in which the artifact copier runs"
  type        = string
}

variable "push_service_accounts" {
  description = "Kubernetes service accounts (in push_namespace) that run the artifact copier and receive write access via Workload Identity"
  type        = list(string)

  validation {
    condition     = length(var.push_service_accounts) > 0
    error_message = "push_service_accounts must contain at least one service account."
  }
}

variable "immutable_tags" {
  description = "Reject tag overwrites in the repository. Mirrored artifacts are addressed by digest, so tags may stay mutable."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Additional labels applied to the repository"
  type        = map(string)
  default     = {}
}

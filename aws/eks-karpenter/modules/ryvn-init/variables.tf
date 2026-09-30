variable "environment_name" {
  description = "Names the CodeBuild project, IAM role, security group, log group and result parameter."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster that ryvn-init bootstraps."
  type        = string
}

variable "cluster_endpoint" {
  description = "API server endpoint of the cluster."
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority of the cluster."
  type        = string
}

variable "cluster_security_group_id" {
  description = "Security group on the cluster's API endpoint. The build is allowed in on 443."
  type        = string
}

variable "vpc_id" {
  description = "VPC the build runs in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets owned by this account, with a NAT or another route to the internet."
  type        = list(string)
}

variable "cilium" {
  description = "Cilium chart version and Helm values to install. repair = true reinstalls them even when Ryvn manages the release. restart_pods_blocked_by_disruption_budgets = true deletes pods whose PodDisruptionBudgets never allow evicting them instead of failing, which takes their workloads down."
  type = object({
    chart_version                              = string
    values                                     = any
    repair                                     = optional(bool, false)
    restart_pods_blocked_by_disruption_budgets = optional(bool, false)
  })
}

variable "image" {
  description = "ryvn-init image."
  type        = string
}

variable "timeout_seconds" {
  description = "Deadline for installing Cilium. On a new cluster, nodes that stay NotReady for about 15 minutes fail their node group, so keep it below that."
  type        = number
  default     = 780
}

variable "migration_timeout_seconds" {
  description = "Extra time to move nodes from the VPC CNI to Cilium, one at a time. Keep it under the lifetime of the credentials Terraform runs with."
  type        = number
  default     = 10800
}

variable "iam_permissions_boundary_arn" {
  description = "Permissions boundary for the CodeBuild service role."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for every resource this module creates."
  type        = map(string)
  default     = {}
}

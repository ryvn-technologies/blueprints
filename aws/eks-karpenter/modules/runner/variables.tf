variable "cluster_name" {
  description = "Name of the EKS cluster the runner can access."
  type        = string
}

variable "cluster_security_group_id" {
  description = "Security group on the EKS API endpoint. The runner connects to it on port 443."
  type        = string
}

variable "vpc_id" {
  description = "VPC where the runner connects to the cluster."
  type        = string
}

variable "name_prefix" {
  description = "Hub prefix for new runner resource names."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.name_prefix))
    error_message = "Use 2 to 12 lowercase letters or digits, starting with a letter."
  }
}

variable "iam_permissions_boundary_arn" {
  description = "Permissions boundary for the runner's IAM role."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for runner resources other than the IAM instance profile."
  type        = map(string)
  default     = {}
}

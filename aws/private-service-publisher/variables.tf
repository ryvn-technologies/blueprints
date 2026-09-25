variable "region" {
  description = "Region of the internal gateway load balancer."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster whose AWS Load Balancer Controller manages the internal gateway's load balancer."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for the names of the resources this module creates."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name_prefix))
    error_message = "name_prefix must use lowercase letters, digits and hyphens, start with a letter and end with a letter or digit."
  }
}

variable "gateway_service" {
  description = "Kubernetes Service (<namespace>/<name>) of the internal gateway. Its Network Load Balancer is what gets published."
  type        = string
  default     = "ryvn-system/internal-ryvn-istio"
}

variable "allowed_consumers" {
  description = "AWS account IDs allowed to connect. Empty allows only this environment's own account."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for account in var.allowed_consumers : can(regex("^[0-9]{12}$", account))])
    error_message = "Allowed Consumers must be 12-digit AWS account IDs."
  }
}

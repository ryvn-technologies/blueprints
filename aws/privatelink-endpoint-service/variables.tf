variable "region" {
  description = "Region to create the endpoint service in. The load balancer must be in the same region."
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

variable "network_load_balancer_tags" {
  description = "Tags of the Network Load Balancer to publish. Exactly one load balancer in the region must have all of them."
  type        = map(string)

  validation {
    condition     = length(var.network_load_balancer_tags) > 0
    error_message = "network_load_balancer_tags needs at least one tag."
  }
}

variable "acceptance_required" {
  description = "Whether each endpoint connection must be accepted before it can carry traffic."
  type        = bool
  default     = true
}

variable "allowed_principals" {
  description = "IAM principal ARNs allowed to connect, such as arn:aws:iam::123456789012:root for a whole account. Empty allows only this account."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for principal in var.allowed_principals : can(regex("^arn:[^:]+:iam::[0-9]{12}:.+$", principal))])
    error_message = "allowed_principals must be IAM principal ARNs, such as arn:aws:iam::123456789012:root."
  }
}

variable "supported_regions" {
  description = "Regions consumers may connect from. region is always included."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for region in var.supported_regions : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", region))])
    error_message = "supported_regions must be AWS region codes, such as us-west-2."
  }
}

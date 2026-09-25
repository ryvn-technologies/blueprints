variable "region" {
  description = "Region of this environment's VPC. Must be the publisher's region."
  type        = string
}

variable "vpc_id" {
  description = "VPC that gets the endpoint. Every CIDR associated with it may reach the endpoint on TCP 80 and 443."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets the endpoint may use. It takes one per availability zone the publisher supports."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids must list at least one subnet."
  }
}

variable "name_prefix" {
  description = "Prefix for the names of the resources this module creates."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name_prefix))
    error_message = "name_prefix must use lowercase letters, digits and hyphens, start with a letter and end with a letter or digit."
  }
}

variable "publisher_id" {
  description = "publisher_id output of the private service publisher: its endpoint service name."
  type        = string

  validation {
    condition     = can(regex("^com\\.amazonaws\\.vpce\\.[a-z0-9-]+\\.vpce-svc-[0-9a-f]+$", var.publisher_id))
    error_message = "Publisher ID isn't valid. Copy the publisherId output of the Private Service Publisher installation."
  }
}

variable "publisher_domain" {
  description = "publisherDomain of the same publisher: the internal domain of the environment it publishes, without a trailing dot."
  type        = string

  validation {
    condition     = var.publisher_domain == lower(var.publisher_domain) && !endswith(var.publisher_domain, ".")
    error_message = "Publisher Domain isn't valid. Copy the publisherDomain output of the Private Service Publisher installation."
  }
}

variable "project_id" {
  description = "GCP project of the environment. The PSC endpoint, firewall rules and private zone are created here."
  type        = string
}

variable "network" {
  description = "Self link of the environment's VPC network."
  type        = string
}

variable "subnetwork" {
  description = "ID or self link of the subnet that the PSC endpoint takes its IP address from. Must be in network."
  type        = string
}

variable "subnetwork_region" {
  description = "Region of subnetwork. Must be the publisher's region."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for the names of the resources this module creates. Names get a random suffix; prefixes longer than 31 characters are shortened."
  type        = string

  validation {
    condition     = can(regex("^[a-z][-a-z0-9]*$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter and use only lowercase letters, digits and hyphens."
  }
}

variable "publisher_id" {
  description = "publisher_id output of the private service publisher: its service attachment ID."
  type        = string

  validation {
    condition     = can(regex("^projects/[^/]+/regions/[^/]+/serviceAttachments/[^/]+$", var.publisher_id))
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

variable "project_id" {
  description = "GCP project of the environment. It holds the internal gateway load balancer and gets the service attachment."
  type        = string
}

variable "region" {
  description = "Region of the internal gateway load balancer."
  type        = string
}

variable "network" {
  description = "Self link of the environment's VPC network."
  type        = string

  validation {
    condition     = can(regex("^https://www\\.googleapis\\.com/compute/v1/projects/[^/]+/global/networks/[^/]+$", var.network))
    error_message = "network must be a VPC self link: https://www.googleapis.com/compute/v1/projects/<project>/global/networks/<name>."
  }
}

variable "name_prefix" {
  description = "Prefix for the names of the resources this module creates. Names get a suffix hashed from the network and prefix; prefixes longer than 31 characters are shortened."
  type        = string

  validation {
    condition     = can(regex("^[a-z][-a-z0-9]*$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter and use only lowercase letters, digits and hyphens."
  }
}

variable "gateway_service" {
  description = "Kubernetes Service (<namespace>/<name>) of the internal gateway. Its GKE internal passthrough load balancer is what gets published."
  type        = string
  default     = "ryvn-system/internal-ryvn-istio"
}

variable "nat_subnet_cidr" {
  description = "IPv4 range of the PSC NAT subnet. Connections from consumers reach the gateway from this range."
  type        = string
  # Benchmarking range (RFC 2544): outside RFC 1918 and Tailscale's 100.64.0.0/10.
  default = "198.18.0.0/28"

  validation {
    condition     = can(cidrnetmask(var.nat_subnet_cidr))
    error_message = "NAT Subnet Range must be an IPv4 range, such as 198.18.0.0/28."
  }
}

variable "allowed_consumers" {
  description = "GCP project IDs allowed to connect. Empty allows only project_id."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = !contains(var.allowed_consumers, "*")
    error_message = "Allowed Consumers can't include \"*\". List the GCP project IDs of the environments that connect."
  }
}

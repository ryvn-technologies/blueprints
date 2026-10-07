variable "enabled" {
  type        = bool
  default     = false
  description = "Configure AppGW with the platform-planned backend IP, independently of Kubernetes deployment or backend health."
}

variable "name" {
  type        = string
  default     = "ryvn-appgw"
  description = "AppGW name; the public IP and NSG are named pip-<name> and nsg-<name>. Import existing resources explicitly."
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9-]{0,63}$", var.name))
    error_message = "name must start with a letter and contain at most 64 letters, digits or hyphens."
  }
}

variable "network" {
  description = "Version 2 platform output shared with the Helm backend Service. The dedicated frontend IP is a planned address, not a reservation or readiness signal."
  type = object({
    version             = number
    resource_group_name = string
    location            = string
    subnet_id           = string
    subnet_cidr         = string
    backend = object({
      subnet_id   = string
      subnet_name = string
      subnet_cidr = string
      private_ip  = string
    })
  })
  default = null
  validation {
    condition = !var.enabled || try(
      var.network.version == 2 &&
      can(cidrnetmask(var.network.subnet_cidr)) &&
      can(cidrnetmask(var.network.backend.subnet_cidr)) &&
      var.network.subnet_id != var.network.backend.subnet_id &&
      tonumber(split("/", var.network.subnet_cidr)[1]) <= 24 &&
      tonumber(split("/", var.network.backend.subnet_cidr)[1]) <= 29 &&
      var.network.backend.subnet_name == "ingress-lb-subnet" &&
    var.network.backend.private_ip == cidrhost(var.network.backend.subnet_cidr, 4), false)
    error_message = "Enabled AppGW requires network version 2, a dedicated AppGW subnet of /24 or larger, and a separate ingress-lb-subnet with usable host 4 as its planned IPv4."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Owner tags for AppGW, public IP and NSG."
}

variable "name" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "azs" {
  description = "Availability zones the environment uses; every group's zones must come from this list."
  type        = list(string)
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "reserved_cidrs" {
  description = "Existing and reserved subnet CIDRs (cluster, public, intra, NAT, firewall, growth slots) that no group may overlap."
  type        = list(string)
  default     = []
}
variable "groups" {
  description = "Ordered, append-only allocation ledger: one subnet per group and availability zone. ipv4_prefix_length is the subnet size, not its address. retired = true keeps the entry (and its address span) while removing its subnets."
  type = list(object({
    name               = string
    ipv4_prefix_length = number
    availability_zones = list(string)
    retired            = optional(bool, false)
  }))
  default = []

  validation {
    condition     = length(distinct(var.groups[*].name)) == length(var.groups) && !contains(var.groups[*].name, "cluster")
    error_message = "additional_subnet_groups names must be unique and may not be \"cluster\" (reserved for the built-in cluster group)."
  }
  validation {
    condition     = alltrue([for group in var.groups : can(regex("^[a-z][a-z0-9_]{0,31}$", group.name))])
    error_message = "additional_subnet_groups names must match ^[a-z][a-z0-9_]{0,31}$ so they can key Terraform resources and attachments."
  }
  validation {
    condition     = alltrue([for group in var.groups : length(group.availability_zones) > 0 && length(distinct(group.availability_zones)) == length(group.availability_zones)])
    error_message = "additional_subnet_groups availability_zones must be a nonempty, duplicate-free ordered list."
  }
}

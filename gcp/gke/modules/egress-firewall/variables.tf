terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.46.0"
    }
  }
}

variable "name" { type = string }
variable "project_id" { type = string }
variable "network_id" { type = string }
variable "zones" {
  type = set(string)
  validation {
    condition     = length(var.zones) > 0
    error_message = "Declare every workload zone; at least one zonal inspection endpoint is required."
  }
}
variable "internal_destination_cidrs" { type = list(string) }
variable "classes" {
  type = map(object({
    policy_key = string
    sources    = list(string)
  }))
}
variable "policies" {
  type = map(object({
    domain_allow = map(object({
      domains           = set(string)
      protocol          = string
      destination_ports = optional(set(number))
    }))
    network_allow = map(object({
      destination_ipv4_cidrs = set(string)
      protocol               = string
      destination_ports      = set(number)
      reason                 = string
    }))
  }))
}
variable "platform_https_domains" { type = set(string) }

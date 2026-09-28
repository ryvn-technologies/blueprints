variable "region" {
  description = "Region of the VPC. An endpoint service in another region must list it in its supported regions."
  type        = string
}

variable "vpc_id" {
  description = "VPC that gets the endpoint. Every CIDR associated with it may reach the endpoint on TCP 80 and 443."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets the endpoint may use. It takes one per availability zone that the endpoint service supports."
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

variable "endpoint_service_name" {
  description = "Name of the endpoint service to connect to (com.amazonaws.vpce.<region>.vpce-svc-<id>)."
  type        = string

  validation {
    condition     = can(regex("^com\\.amazonaws\\.vpce\\.[a-z0-9-]+\\.vpce-svc-[0-9a-f]+$", var.endpoint_service_name))
    error_message = "endpoint_service_name must look like com.amazonaws.vpce.<region>.vpce-svc-<id>."
  }
}

variable "private_hosted_zone_name" {
  description = "Private hosted zone to create in the VPC, without a trailing dot. Every name under it resolves to the endpoint."
  type        = string

  validation {
    condition     = var.private_hosted_zone_name == lower(var.private_hosted_zone_name) && !endswith(var.private_hosted_zone_name, ".")
    error_message = "private_hosted_zone_name must be lowercase, without a trailing dot."
  }
}

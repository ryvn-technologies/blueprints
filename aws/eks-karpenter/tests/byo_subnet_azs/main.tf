variable "workload_subnets" {
  type = list(object({
    id                = string
    availability_zone = string
  }))
}

locals {
  # --- This logic mirrors infra/aws-provision-karpenter/network.tf ---
  byo_provided_workload     = var.workload_subnets
  byo_provided_workload_azs = distinct([for s in local.byo_provided_workload : s.availability_zone])

  byo_provided_workload_duplicate_azs = [
    for az in local.byo_provided_workload_azs : az
    if length([for s in local.byo_provided_workload : s.id if s.availability_zone == az]) > 1
  ]
}

output "azs" {
  value = local.byo_provided_workload_azs
}

output "duplicate_azs" {
  value = local.byo_provided_workload_duplicate_azs
}

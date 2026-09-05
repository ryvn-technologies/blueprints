locals {
  azs = coalesce(var.zones, module.regions.regions_by_name[var.location].zones)
}

module "regions" {
  source                   = "Azure/regions/azurerm"
  version                  = "0.8.2"
  recommended_regions_only = false
}

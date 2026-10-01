locals {
  # Full audit includes read requests; kube-audit-admin would omit get/list.
  control_plane_log_categories = [
    "kube-apiserver",
    "kube-controller-manager",
    "kube-scheduler",
    "cluster-autoscaler",
    "guard",
    "kube-audit",
  ]
}

resource "azurerm_log_analytics_workspace" "control_plane" {
  name                            = trim(substr("log-${local.cluster_name}", 0, 63), "-")
  location                        = var.location
  resource_group_name             = azurerm_resource_group.rg.name
  sku                             = "PerGB2018"
  retention_in_days               = var.control_plane_log_retention_days
  local_authentication_enabled    = false
  allow_resource_only_permissions = false
  tags                            = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "control_plane" {
  name                           = "ryvn-control-plane-logs"
  target_resource_id             = module.aks.aks_id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.control_plane.id
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = toset(local.control_plane_log_categories)
    content {
      category = enabled_log.value
    }
  }
}

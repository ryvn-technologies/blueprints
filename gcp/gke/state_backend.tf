module "state_backend" {
  source = "./modules/state-backend"
  count  = var.managed_state_backend_enabled ? 1 : 0

  project_id                  = var.project_id
  location                    = var.region
  environment_id              = var.environment_id
  agent_service_account_email = google_service_account.ryvn_agent.email
}

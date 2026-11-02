variable "project_id" {
  type     = string
  nullable = false
}

variable "location" {
  type     = string
  nullable = false
}

variable "environment_id" {
  description = "Stable environment UUID from the trusted template context, never its display name."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.environment_id))
    error_message = "environment_id must be a canonical lowercase environment UUID."
  }
}

variable "agent_service_account_email" {
  type     = string
  nullable = false
}

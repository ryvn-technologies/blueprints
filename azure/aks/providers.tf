terraform {
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0, < 3.0"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.67"
    }
  }
}

provider "azurerm" {
  resource_provider_registrations = "none"
  features {}
}

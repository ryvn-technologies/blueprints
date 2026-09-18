mock_provider "azurerm" {
  mock_data "azurerm_kubernetes_cluster" {
    defaults = {
      oidc_issuer_url  = "https://eastus.oic.prod-aks.azure.com/tenant/cluster/"
      kubelet_identity = [{ object_id = "11111111-1111-1111-1111-111111111111" }]
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prod/providers/Microsoft.ManagedIdentity/userAssignedIdentities/registryabcd1234-push"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
      tenant_id    = "55555555-5555-5555-5555-555555555555"
    }
  }

  mock_resource "azurerm_container_registry" {
    defaults = {
      login_server = "registryabcd1234.azurecr.io"
      id           = "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ContainerRegistry/registries/registryabcd1234"
    }
  }
}

mock_provider "random" {
  mock_resource "random_id" {
    defaults = {
      hex = "abcd1234"
    }
  }
}

variables {
  location              = "eastus"
  resource_group_name   = "rg-prod"
  environment           = "prod"
  cluster_name          = "prod-aks"
  push_namespace        = "ryvn"
  push_service_accounts = ["mirror-sync"]
}

run "detects_kubelet_identity_and_issuer_from_cluster" {
  command = plan

  assert {
    condition     = tolist(local.node_principal_ids) == tolist(["11111111-1111-1111-1111-111111111111"])
    error_message = "The kubelet identity must be taken from the cluster."
  }

  assert {
    condition     = azurerm_federated_identity_credential.push["mirror-sync"].issuer == "https://eastus.oic.prod-aks.azure.com/tenant/cluster/"
    error_message = "The federated credential must use the cluster's OIDC issuer."
  }

  assert {
    condition     = azurerm_federated_identity_credential.push["mirror-sync"].subject == "system:serviceaccount:ryvn:mirror-sync"
    error_message = "The federated credential subject must target the copier service account."
  }
}

run "explicit_identities_skip_cluster_lookup" {
  command = plan

  variables {
    cluster_name       = ""
    node_principal_ids = ["22222222-2222-2222-2222-222222222222"]
    oidc_issuer_url    = "https://attached.example.com/oidc"
  }

  assert {
    condition     = length(data.azurerm_kubernetes_cluster.this) == 0
    error_message = "Attached clusters must not trigger an AKS lookup."
  }

  assert {
    condition     = length(azurerm_role_assignment.node_pull) == 1 && azurerm_role_assignment.node_pull["22222222-2222-2222-2222-222222222222"].role_definition_name == "AcrPull"
    error_message = "Explicit kubelet identities must receive AcrPull."
  }
}

run "agent_pull_principals_are_merged_and_deduplicated" {
  command = plan

  variables {
    pull_principal_ids = [
      "11111111-1111-1111-1111-111111111111",
      "22222222-2222-2222-2222-222222222222",
    ]
  }

  assert {
    condition     = length(azurerm_role_assignment.node_pull) == 2
    error_message = "Agent and kubelet principals must receive one deduplicated AcrPull assignment each."
  }
}

run "null_explicit_node_identities_fall_back_to_detection" {
  command = plan

  variables {
    node_principal_ids = null
  }

  assert {
    condition     = tolist(local.node_principal_ids) == tolist(["11111111-1111-1111-1111-111111111111"])
    error_message = "A null node_principal_ids (rendered from an empty blueprint list) must behave like an empty list and keep detected identities."
  }
}

run "fails_without_node_identity" {
  command = plan

  variables {
    cluster_name    = ""
    oidc_issuer_url = "https://attached.example.com/oidc"
  }

  expect_failures = [
    azurerm_container_registry.this,
  ]
}

run "fails_without_oidc_issuer" {
  command = plan

  variables {
    cluster_name       = ""
    node_principal_ids = ["22222222-2222-2222-2222-222222222222"]
  }

  expect_failures = [
    azurerm_container_registry.this,
  ]
}

run "registry_is_locked_down_and_named_safely" {
  command = apply

  variables {
    registry_name = "Payments_Mirror"
  }

  assert {
    condition     = azurerm_container_registry.this.name == "paymentsmirrorabcd1234"
    error_message = "ACR names must be lowercase alphanumeric with the random suffix appended."
  }

  assert {
    condition     = azurerm_container_registry.this.admin_enabled == false && azurerm_container_registry.this.anonymous_pull_enabled == false
    error_message = "Admin credentials and anonymous pull must stay disabled."
  }
}

run "long_registry_names_keep_the_random_suffix" {
  command = apply

  variables {
    registry_name = "an-extremely-long-registry-name-that-would-otherwise-swallow-the-suffix"
  }

  assert {
    condition     = length(local.registry_name) == 50 && endswith(local.registry_name, "abcd1234")
    error_message = "The base must be truncated before the suffix so global uniqueness is preserved."
  }
}

run "outputs_form_the_registry_contract" {
  command = apply

  assert {
    condition     = output.registry_host == "registryabcd1234.azurecr.io" && output.destination_base == output.registry_host
    error_message = "Destination base must be the login server."
  }

  assert {
    condition     = output.registry_definition.type == "genericContainerRegistry" && output.registry_definition.credentials.type == "clusterDefault"
    error_message = "ACR is exposed as a generic registry with clusterDefault credentials."
  }

  assert {
    condition     = output.push_identity.method == "azureWorkloadIdentity" && output.push_identity.role == "AcrPush"
    error_message = "Push must go through Workload Identity with AcrPush."
  }
}

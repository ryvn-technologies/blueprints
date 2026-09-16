mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }

  mock_data "google_container_cluster" {
    defaults = {
      node_pool = [
        { node_config = [{ service_account = "default" }] },
        { node_config = [{ service_account = "nodes@test-project.iam.gserviceaccount.com" }] },
        { node_config = [{ service_account = "nodes@test-project.iam.gserviceaccount.com" }] },
      ]
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
  project_id            = "test-project"
  region                = "us-central1"
  environment           = "prod"
  cluster_name          = "prod-gke"
  push_namespace        = "ryvn"
  push_service_accounts = ["mirror-sync"]
}

run "detects_node_service_accounts_from_cluster" {
  command = plan

  assert {
    condition = toset(local.node_service_accounts) == toset([
      "123456789012-compute@developer.gserviceaccount.com",
      "nodes@test-project.iam.gserviceaccount.com",
    ])
    error_message = "Node pools using the default compute service account must resolve to the project's compute SA and duplicates must collapse."
  }

  assert {
    condition     = length(google_artifact_registry_repository_iam_member.pull) == 2
    error_message = "One reader grant per distinct node service account is expected."
  }
}

run "explicit_node_identities_skip_cluster_lookup" {
  command = plan

  variables {
    cluster_name          = ""
    node_service_accounts = ["attached-nodes@other-project.iam.gserviceaccount.com"]
  }

  assert {
    condition     = length(data.google_container_cluster.this) == 0
    error_message = "Attached clusters must not trigger a GKE cluster lookup."
  }

  assert {
    condition     = output.pull_identity.serviceAccounts == tolist(["attached-nodes@other-project.iam.gserviceaccount.com"])
    error_message = "Explicit node service accounts must be used verbatim."
  }
}

run "fails_without_any_node_identity" {
  command = plan

  variables {
    cluster_name = ""
  }

  expect_failures = [
    google_artifact_registry_repository.this,
  ]
}

run "allows_missing_node_identity_when_not_required" {
  command = plan

  variables {
    cluster_name            = ""
    require_node_pull_grant = false
  }

  assert {
    condition     = length(google_artifact_registry_repository_iam_member.pull) == 0
    error_message = "No pull grants are expected when node identities are intentionally omitted."
  }
}

run "registry_name_is_normalised_for_artifact_registry" {
  command = apply

  variables {
    registry_name = "Payments_Mirror.EU-with-a-very-long-suffix-that-keeps-going-and-going"
  }

  assert {
    condition     = local.repository_id == "payments-mirror-eu-with-a-very-long-suffix-that-keeps-abcd1234"
    error_message = "Repository ids must be lowercase [a-z0-9-], base truncated so the suffix survives and the id stays under 63 chars."
  }
}

run "digit_leading_and_empty_registry_names_get_a_letter_prefix" {
  command = apply

  variables {
    registry_name = "123"
  }

  assert {
    condition     = local.repository_id == "registry-123-abcd1234"
    error_message = "Repository ids must start with a letter."
  }
}

run "punctuation_only_registry_name_falls_back_to_a_valid_id" {
  command = apply

  variables {
    registry_name = "!!!"
  }

  assert {
    condition     = local.repository_id == "registry-abcd1234"
    error_message = "A name that sanitises to nothing must fall back to a valid base."
  }
}

run "outputs_form_the_registry_contract" {
  command = apply

  assert {
    condition     = output.registry_host == "us-central1-docker.pkg.dev"
    error_message = "Registry host must be derived from the location."
  }

  assert {
    condition     = output.destination_base == "us-central1-docker.pkg.dev/test-project/registry-abcd1234"
    error_message = "destination_base must be <host>/<project>/<repository>."
  }

  assert {
    condition     = output.registry_definition.type == "googleArtifactRegistry" && output.registry_definition.projectId == "test-project"
    error_message = "registry_definition must match the GoogleArtifactRegistry API shape."
  }

  assert {
    condition     = output.push_identity.members[0] == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/test-project.svc.id.goog/subject/ns/ryvn/sa/mirror-sync"
    error_message = "Push access must be granted to the copier's Workload Identity principal, not a key."
  }

  assert {
    condition     = google_artifact_registry_repository.this.cleanup_policies == null || length(google_artifact_registry_repository.this.cleanup_policies) == 0
    error_message = "Mirrored artifacts must be preserved by default: no cleanup policies."
  }
}

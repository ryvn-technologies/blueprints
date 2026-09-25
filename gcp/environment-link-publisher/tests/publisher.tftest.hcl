mock_provider "google" {}

variables {
  project_id  = "cp-project"
  region      = "us-central1"
  network     = "https://www.googleapis.com/compute/v1/projects/cp-project/global/networks/gke-network-cp"
  name_prefix = "environment-link-publisher"
}

override_data {
  target = data.google_compute_forwarding_rules.in_region
  values = {
    rules = [
      {
        name        = "a0f1e2d3c4b5a6978"
        description = "{\"kubernetes.io/service-name\":\"ryvn-system/internal-ryvn-istio\"}"
        network     = "https://www.googleapis.com/compute/v1/projects/cp-project/global/networks/gke-network-cp"
      },
      {
        name        = "k8s2-tcp-other"
        description = "{\"networking.gke.io/service-name\":\"ryvn-system/other\",\"networking.gke.io/api-version\":\"ga\"}"
        network     = "https://www.googleapis.com/compute/v1/projects/cp-project/global/networks/gke-network-cp"
      },
      {
        name        = "k8s2-tcp-istio-extra"
        description = "{\"networking.gke.io/service-name\":\"ryvn-system/internal-ryvn-istio-extra\",\"networking.gke.io/api-version\":\"ga\"}"
        network     = "https://www.googleapis.com/compute/v1/projects/cp-project/global/networks/gke-network-cp"
      },
      {
        name        = "a-other-environment"
        description = "{\"kubernetes.io/service-name\":\"ryvn-system/internal-ryvn-istio\"}"
        network     = "https://www.googleapis.com/compute/v1/projects/cp-project/global/networks/gke-network-other"
      },
      {
        name    = "manual-rule-without-description"
        network = "https://www.googleapis.com/compute/v1/projects/cp-project/global/networks/gke-network-cp"
      },
    ]
  }
}

override_data {
  target = data.google_compute_forwarding_rule.gateway
  values = {
    load_balancing_scheme = "INTERNAL"
    all_ports             = false
    ports                 = ["80", "443", "15021"]
    self_link             = "https://www.googleapis.com/compute/v1/projects/cp-project/regions/us-central1/forwardingRules/a0f1e2d3c4b5a6978"
  }
}

run "no_gateway_rule_fails" {
  command = plan

  override_data {
    target = data.google_compute_forwarding_rules.in_region
    values = {
      rules = [
        {
          name        = "k8s2-tcp-other"
          description = "{\"networking.gke.io/service-name\":\"ryvn-system/other\",\"networking.gke.io/api-version\":\"ga\"}"
          network     = "https://www.googleapis.com/compute/v1/projects/cp-project/global/networks/gke-network-cp"
        },
      ]
    }
  }

  expect_failures = [
    data.google_compute_forwarding_rule.gateway,
  ]
}

run "two_gateway_rules_fail" {
  command = plan

  override_data {
    target = data.google_compute_forwarding_rules.in_region
    values = {
      rules = [
        {
          name        = "a0f1e2d3c4b5a6978"
          description = "{\"kubernetes.io/service-name\":\"ryvn-system/internal-ryvn-istio\"}"
          network     = "https://www.googleapis.com/compute/v1/projects/cp-project/global/networks/gke-network-cp"
        },
        {
          name        = "k8s2-tcp-internal-ryvn-istio"
          description = "{\"networking.gke.io/service-name\":\"ryvn-system/internal-ryvn-istio\",\"networking.gke.io/api-version\":\"ga\"}"
          network     = "https://www.googleapis.com/compute/v1/projects/cp-project/global/networks/gke-network-cp"
        },
      ]
    }
  }

  expect_failures = [
    data.google_compute_forwarding_rule.gateway,
  ]
}

run "external_gateway_rule_fails" {
  command = plan

  override_data {
    target = data.google_compute_forwarding_rule.gateway
    values = {
      load_balancing_scheme = "EXTERNAL"
      all_ports             = false
      ports                 = ["80", "443"]
    }
  }

  expect_failures = [
    data.google_compute_forwarding_rule.gateway,
  ]
}

run "gateway_without_port_80_fails" {
  command = plan

  override_data {
    target = data.google_compute_forwarding_rule.gateway
    values = {
      load_balancing_scheme = "INTERNAL"
      all_ports             = false
      ports                 = ["443", "15021"]
    }
  }

  expect_failures = [
    data.google_compute_forwarding_rule.gateway,
  ]
}

run "publishes_the_internal_gateway" {
  command = plan

  assert {
    condition     = data.google_compute_forwarding_rule.gateway.name == "a0f1e2d3c4b5a6978"
    error_message = "Only the rule for Service ryvn-system/internal-ryvn-istio on this environment's network may match."
  }

  assert {
    condition     = local.consumer_accept_lists == [{ project_id_or_num = "cp-project", connection_limit = 10 }]
    error_message = "An empty allowed_consumers must accept only the environment's own project."
  }

  assert {
    condition     = google_compute_firewall.allow_http_from_psc_nat.source_ranges == toset(["198.18.0.0/28"]) && one(google_compute_firewall.allow_http_from_psc_nat.allow).ports == tolist(["80"])
    error_message = "The firewall must admit only HTTP from the PSC NAT subnet."
  }
}

run "allowed_consumers_replace_the_own_project" {
  command = plan

  variables {
    allowed_consumers = ["other-project"]
  }

  assert {
    condition     = local.consumer_accept_lists == [{ project_id_or_num = "other-project", connection_limit = 10 }]
    error_message = "allowed_consumers must be the service attachment's accept list."
  }
}

run "long_name_prefixes_are_shortened" {
  command = plan

  variables {
    name_prefix = "environment-link-publisher-with-a-long-installation-name"
  }

  assert {
    condition     = local.resource_name_prefix == "environment-link-publisher-with-a-8a0990"
    error_message = "Prefixes over 40 characters must keep their first 33 characters plus a hash of the full prefix."
  }
}

run "wildcard_consumer_is_rejected" {
  command = plan

  variables {
    allowed_consumers = ["*"]
  }

  expect_failures = [
    var.allowed_consumers,
  ]
}

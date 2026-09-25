mock_provider "google" {}

mock_provider "random" {
  mock_resource "random_id" {
    defaults = {
      hex = "abcd1234"
    }
  }
}

variables {
  project_id        = "dp-project"
  network           = "https://www.googleapis.com/compute/v1/projects/dp-project/global/networks/gke-network-dp"
  subnetwork        = "projects/dp-project/regions/us-central1/subnetworks/gke-subnet-dp"
  subnetwork_region = "us-central1"
  name_prefix       = "cp-link"
  publisher_id      = "projects/cp-project/regions/us-central1/serviceAttachments/private-service-publisher"
  publisher_domain  = "cp.ryvn.internal"
}

override_resource {
  target = module.psc_endpoint.google_compute_address.private_service_connect_regional_address
  values = {
    address = "10.0.0.50"
  }
}

override_resource {
  target = module.psc_endpoint.google_compute_forwarding_rule.private_service_connect_for_published_services
  values = {
    id = "projects/dp-project/regions/us-central1/forwardingRules/cp-link-abcd1234-psc-endpoint"
  }
}

run "region_mismatch_fails" {
  command = plan

  variables {
    subnetwork_region = "europe-west1"
  }

  expect_failures = [
    terraform_data.publisher_region_check,
  ]
}

run "connects_to_the_publisher" {
  command = apply

  assert {
    condition     = google_compute_firewall.allow_http_to_psc_endpoint.priority < google_compute_firewall.deny_other_to_psc_endpoint.priority && one(google_compute_firewall.allow_http_to_psc_endpoint.allow).ports == tolist(["80", "443"]) && one(google_compute_firewall.deny_other_to_psc_endpoint.deny).protocol == "all"
    error_message = "Egress to the endpoint must allow only TCP 80 and 443: the allow rule must win over the deny-all rule."
  }

  assert {
    condition     = google_compute_firewall.allow_http_to_psc_endpoint.destination_ranges == toset(["10.0.0.50/32"]) && google_compute_firewall.deny_other_to_psc_endpoint.destination_ranges == toset(["10.0.0.50/32"])
    error_message = "Both egress rules must target only the endpoint IP."
  }

  assert {
    condition     = google_dns_record_set.publisher_domain_wildcard.name == "*.cp.ryvn.internal." && google_dns_record_set.publisher_domain_wildcard.rrdatas == tolist(["10.0.0.50"])
    error_message = "Every name in publisher_domain must resolve to the endpoint IP."
  }
}

run "malformed_publisher_id_fails" {
  command = plan

  variables {
    publisher_id = "https://www.googleapis.com/compute/v1/projects/cp-project/regions/us-central1/serviceAttachments/private-service-publisher"
  }

  expect_failures = [
    var.publisher_id,
  ]
}

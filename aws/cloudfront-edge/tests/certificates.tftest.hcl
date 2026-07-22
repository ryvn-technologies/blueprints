mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"
}

mock_provider "random" {}

variables {
  managed_public_dns_root  = "net-playground.example.com"
  managed_private_dns_root = "internal.net-playground.example.com"
  origin_type              = "vpc"
  vpc_origin = {
    existing_vpc_origin_id = "vpc-origin-test"
  }
  cache_policy_id          = "cache-policy-test"
  cache_policy_name        = ""
  origin_request_policy_id = "origin-request-policy-test"
  wait_for_deployment      = false
}

run "explicit_hostnames_use_exact_certificate" {
  command = plan

  variables {
    hostnames = [
      "api.net-playground.example.com",
      "app.net-playground.example.com",
    ]
  }

  assert {
    condition     = aws_acm_certificate.viewer[0].domain_name == "api.net-playground.example.com"
    error_message = "An installation must use its first exact hostname as the managed certificate's primary name."
  }

  assert {
    condition     = toset(aws_acm_certificate.viewer[0].subject_alternative_names) == toset(["app.net-playground.example.com"])
    error_message = "An installation must include only its remaining exact hostnames as certificate SANs."
  }

  assert {
    condition     = toset(keys(aws_route53_record.viewer_certificate_validation_record)) == toset(["api.net-playground.example.com", "app.net-playground.example.com"])
    error_message = "An installation must own one validation-record resource per exact certificate hostname."
  }
}

run "empty_hostnames_use_environment_certificate" {
  command = plan

  variables {
    hostnames = []
  }

  assert {
    condition     = aws_acm_certificate.viewer[0].domain_name == "net-playground.example.com"
    error_message = "An installation without explicit hostnames must keep the environment apex as the certificate's primary name."
  }

  assert {
    condition     = toset(aws_acm_certificate.viewer[0].subject_alternative_names) == toset(["*.net-playground.example.com"])
    error_message = "An installation without explicit hostnames must keep the environment wildcard certificate SAN."
  }

  assert {
    condition     = toset(keys(aws_route53_record.viewer_certificate_validation_record)) == toset(["net-playground.example.com"])
    error_message = "A default installation must manage the shared apex/wildcard ACM validation CNAME through exactly one Terraform resource."
  }

  assert {
    condition     = length(aws_acm_certificate_validation.viewer[0].validation_record_fqdns) == 1
    error_message = "The apex/wildcard certificate validation must use the one shared ACM validation CNAME."
  }
}

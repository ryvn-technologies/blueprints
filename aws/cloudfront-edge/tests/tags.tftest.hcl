mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"
}

mock_provider "random" {}

variables {
  managed_public_dns_root  = "edge.example.invalid"
  managed_private_dns_root = "internal.edge.example.invalid"
  origin_type              = "vpc"
  vpc_origin = {
    existing_vpc_origin_id = "vpc-origin-test"
  }
  origin_request_policy_id = "origin-request-policy-test"
  viewer_mtls = {
    enabled     = true
    trust_store = { create = true }
  }
  viewer_mtls_ca_bundle_pem = "-----BEGIN CERTIFICATE-----\nmock\n-----END CERTIFICATE-----"
}

run "custom_name_at_tag_limit" {
  command = plan

  variables {
    tags = merge({ Name = "custom-edge" }, { for index in range(9) : "tag-${index}" => "value" })
  }

  assert {
    condition     = aws_s3_bucket.viewer_mtls_ca_bundle["this"].tags.Name == "custom-edge"
    error_message = "The CA bucket must preserve a supplied Name tag."
  }
}

run "managed_ca_object_rejects_eleven_tags" {
  command = plan

  variables {
    tags = { for index in range(11) : "tag-${index}" => "value" }
  }

  expect_failures = [aws_s3_object.viewer_mtls_ca_bundle]
}

mock_provider "aws" {}

variables {
  region           = "us-west-2"
  vpc_id           = "vpc-0dp"
  subnet_ids       = ["subnet-b", "subnet-a"]
  name_prefix      = "dp-cp-link"
  publisher_id     = "com.amazonaws.vpce.us-west-2.vpce-svc-0123456789abcdef0"
  publisher_domain = "cp.ryvn.internal"
}

override_data {
  target = data.aws_vpc_endpoint_service.publisher
  values = {
    availability_zones = ["us-west-2a"]
  }
}

override_data {
  target = data.aws_vpc.endpoint
  values = {
    cidr_block_associations = [
      { association_id = "vpc-cidr-assoc-primary", cidr_block = "10.2.0.0/16", state = "associated" },
      { association_id = "vpc-cidr-assoc-secondary", cidr_block = "100.64.0.0/16", state = "associated" },
    ]
  }
}

# Both subnets are in the one zone the publisher supports.
override_data {
  target = data.aws_subnet.endpoint_candidate
  values = {
    availability_zone = "us-west-2a"
  }
}

override_resource {
  target = aws_vpc_endpoint.publisher
  values = {
    id    = "vpce-0123456789abcdef0"
    state = "available"
    dns_entry = [
      { dns_name = "vpce-0123456789abcdef0-abcdefgh.vpce-svc-0123456789abcdef0.us-west-2.vpce.amazonaws.com", hosted_zone_id = "Z1YSA3EXCYUU9Z" },
      { dns_name = "vpce-0123456789abcdef0-abcdefgh-us-west-2a.vpce-svc-0123456789abcdef0.us-west-2.vpce.amazonaws.com", hosted_zone_id = "Z1YSA3EXCYUU9Z" },
    ]
  }
}

run "region_mismatch_fails" {
  command = plan

  variables {
    publisher_id = "com.amazonaws.vpce.us-east-1.vpce-svc-0123456789abcdef0"
  }

  expect_failures = [
    data.aws_vpc_endpoint_service.publisher,
  ]
}

run "malformed_publisher_id_fails" {
  command = plan

  variables {
    publisher_id = "vpce-svc-0123456789abcdef0"
  }

  expect_failures = [
    var.publisher_id,
  ]
}

run "no_subnet_in_a_supported_zone_fails" {
  command = plan

  override_data {
    target = data.aws_vpc_endpoint_service.publisher
    values = {
      availability_zones = ["us-west-2c"]
    }
  }

  expect_failures = [
    aws_vpc_endpoint.publisher,
  ]
}

run "connects_to_the_publisher" {
  command = apply

  assert {
    condition     = aws_vpc_endpoint.publisher.subnet_ids == toset(["subnet-a"])
    error_message = "The endpoint must take one subnet per supported zone."
  }

  assert {
    condition     = toset([for rule in aws_vpc_security_group_ingress_rule.http_from_vpc : "${rule.ip_protocol}/${rule.from_port}-${rule.to_port}/${rule.cidr_ipv4}"]) == toset(["tcp/80-80/10.2.0.0/16", "tcp/80-80/100.64.0.0/16", "tcp/443-443/10.2.0.0/16", "tcp/443-443/100.64.0.0/16"])
    error_message = "The endpoint must admit only TCP 80 and 443, from every CIDR of the VPC."
  }

  assert {
    condition     = one(aws_route53_record.publisher_domain_wildcard.alias).name == "vpce-0123456789abcdef0-abcdefgh.vpce-svc-0123456789abcdef0.us-west-2.vpce.amazonaws.com"
    error_message = "Every name in publisher_domain must resolve to the endpoint's regional name."
  }
}

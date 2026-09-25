locals {
  publisher_region = regex("^com\\.amazonaws\\.vpce\\.([a-z0-9-]+)\\.", var.publisher_id)[0]
  vpc_cidrs        = [for association in data.aws_vpc.endpoint.cidr_block_associations : association.cidr_block]

  # An endpoint takes at most one subnet per availability zone.
  supported_subnet_ids_by_zone = {
    for id, subnet in data.aws_subnet.endpoint_candidate : subnet.availability_zone => id...
    if contains(data.aws_vpc_endpoint_service.publisher.availability_zones, subnet.availability_zone)
  }
  endpoint_subnet_ids = [for zone in sort(keys(local.supported_subnet_ids_by_zone)) : sort(local.supported_subnet_ids_by_zone[zone])[0]]
}

data "aws_vpc_endpoint_service" "publisher" {
  service_name = var.publisher_id

  lifecycle {
    precondition {
      condition     = local.publisher_region == var.region
      error_message = "This environment is in ${var.region}, but the publisher is in ${local.publisher_region}. Both must be in the same region."
    }
  }
}

data "aws_vpc" "endpoint" {
  id = var.vpc_id
}

data "aws_subnet" "endpoint_candidate" {
  for_each = toset(var.subnet_ids)

  id = each.value
}

resource "aws_security_group" "endpoint" {
  name        = "${var.name_prefix}-environment-link"
  description = "HTTP from this VPC to the environment link endpoint"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-environment-link"
  }
}

resource "aws_vpc_security_group_ingress_rule" "http_from_vpc" {
  for_each = toset(local.vpc_cidrs)

  security_group_id = aws_security_group.endpoint.id
  description       = "HTTP to the environment link endpoint"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_endpoint" "publisher" {
  vpc_id              = var.vpc_id
  service_name        = var.publisher_id
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = false

  tags = {
    Name = "${var.name_prefix}-environment-link"
  }

  lifecycle {
    precondition {
      condition     = length(local.endpoint_subnet_ids) > 0
      error_message = "This environment has no private subnet in the publisher's availability zones (${join(", ", sort(tolist(data.aws_vpc_endpoint_service.publisher.availability_zones)))}). Add one, then install again."
    }
  }
}

resource "aws_route53_zone" "publisher_domain" {
  name    = var.publisher_domain
  comment = "Internal names of the publishing environment, resolved to the environment link endpoint"

  vpc {
    vpc_id = var.vpc_id
  }

  tags = {
    Name = "${var.name_prefix}-environment-link"
  }
}

resource "aws_route53_record" "publisher_domain_wildcard" {
  zone_id = aws_route53_zone.publisher_domain.zone_id
  name    = "*.${var.publisher_domain}"
  type    = "A"

  # The first DNS entry is the endpoint's regional name.
  alias {
    name                   = aws_vpc_endpoint.publisher.dns_entry[0].dns_name
    zone_id                = aws_vpc_endpoint.publisher.dns_entry[0].hosted_zone_id
    evaluate_target_health = false
  }
}

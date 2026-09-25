locals {
  endpoint_service_region = split(".", var.endpoint_service_name)[3]
  vpc_cidrs               = [for association in data.aws_vpc.endpoint.cidr_block_associations : association.cidr_block]

  # An endpoint takes at most one subnet per availability zone.
  supported_subnet_ids_by_zone = {
    for id, subnet in data.aws_subnet.endpoint_candidate : subnet.availability_zone => id...
    if contains(data.aws_vpc_endpoint_service.endpoint_service.availability_zones, subnet.availability_zone)
  }
  endpoint_subnet_ids = [for zone in sort(keys(local.supported_subnet_ids_by_zone)) : sort(local.supported_subnet_ids_by_zone[zone])[0]]
}

# For an endpoint service in another region, availability_zones lists the zones in this region that can connect to it.
data "aws_vpc_endpoint_service" "endpoint_service" {
  service_name    = var.endpoint_service_name
  service_regions = [local.endpoint_service_region]
}

data "aws_vpc" "endpoint" {
  id = var.vpc_id
}

data "aws_subnet" "endpoint_candidate" {
  for_each = toset(var.subnet_ids)

  id = each.value
}

resource "aws_security_group" "endpoint" {
  name_prefix = "${var.name_prefix}-vpce-"
  description = "TCP 80 and 443 from this VPC to the VPC endpoint"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-vpce"
  }

  # The endpoint keeps using this group until it moves to the replacement.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "http_from_vpc" {
  for_each = { for pair in setproduct(local.vpc_cidrs, [80, 443]) : "${pair[0]}:${pair[1]}" => pair }

  security_group_id = aws_security_group.endpoint.id
  description       = "From this VPC to the VPC endpoint"
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
  cidr_ipv4         = each.value[0]
}

resource "aws_vpc_endpoint" "endpoint_service" {
  vpc_id              = var.vpc_id
  service_name        = var.endpoint_service_name
  service_region      = local.endpoint_service_region
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = false

  tags = {
    Name = "${var.name_prefix}-vpce"
  }

  lifecycle {
    precondition {
      condition     = length(local.endpoint_subnet_ids) > 0
      error_message = "No subnet in subnet_ids is in an availability zone the endpoint service supports (${join(", ", sort(tolist(data.aws_vpc_endpoint_service.endpoint_service.availability_zones)))})."
    }
  }
}

resource "aws_route53_zone" "private_hosted_zone" {
  name    = var.private_hosted_zone_name
  comment = "Every name under this zone resolves to the VPC endpoint"

  vpc {
    vpc_id = var.vpc_id
  }

  tags = {
    Name = "${var.name_prefix}-vpce"
  }
}

resource "aws_route53_record" "private_hosted_zone_wildcard" {
  zone_id = aws_route53_zone.private_hosted_zone.zone_id
  name    = "*.${var.private_hosted_zone_name}"
  type    = "A"

  # The first DNS entry is the endpoint's regional name.
  alias {
    name                   = aws_vpc_endpoint.endpoint_service.dns_entry[0].dns_name
    zone_id                = aws_vpc_endpoint.endpoint_service.dns_entry[0].hosted_zone_id
    evaluate_target_health = false
  }
}

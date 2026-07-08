data "aws_lb" "vpc_origin_endpoint" {
  for_each = local.lookup_vpc_origin_endpoint ? { this = var.vpc_origin.endpoint_lookup_tags } : {}

  tags = each.value
}

resource "aws_cloudfront_vpc_origin" "this" {
  for_each = local.create_vpc_origin ? { this = var.vpc_origin } : {}

  provider = aws.us_east_1

  vpc_origin_endpoint_config {
    arn                    = local.vpc_origin_endpoint_arn
    http_port              = each.value.http_port
    https_port             = each.value.https_port
    name                   = trimspace(each.value.name) != "" ? trimspace(each.value.name) : local.resource_name
    origin_protocol_policy = each.value.origin_protocol_policy

    origin_ssl_protocols {
      items    = each.value.origin_ssl_protocols
      quantity = length(each.value.origin_ssl_protocols)
    }
  }

  dynamic "timeouts" {
    for_each = each.value.timeouts != null ? [each.value.timeouts] : []

    content {
      create = timeouts.value.create
      delete = timeouts.value.delete
      update = timeouts.value.update
    }
  }

  tags = merge(var.tags, each.value.tags)
}

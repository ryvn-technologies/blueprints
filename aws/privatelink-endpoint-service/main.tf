locals {
  this_account_root_arn = provider::aws::arn_build(data.aws_partition.current.partition, "iam", "", data.aws_caller_identity.current.account_id, "root")
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_lbs" "tagged" {
  tags = var.network_load_balancer_tags
}

data "aws_lb" "published" {
  arn = one(data.aws_lbs.tagged.arns)

  lifecycle {
    precondition {
      condition     = length(data.aws_lbs.tagged.arns) > 0
      error_message = "No load balancer matches network_load_balancer_tags."
    }
  }
}

resource "aws_vpc_endpoint_service" "published_load_balancer" {
  acceptance_required        = var.acceptance_required
  allowed_principals         = coalescelist(var.allowed_principals, [local.this_account_root_arn])
  network_load_balancer_arns = [data.aws_lb.published.arn]
  supported_ip_address_types = ["ipv4"]
  # AWS always keeps the service's own region in this list, so list it too to avoid a diff.
  supported_regions = setunion([var.region], var.supported_regions)

  tags = {
    Name = var.name_prefix
  }
}

locals {
  # The AWS Load Balancer Controller tags each load balancer with its cluster and Service.
  gateway_load_balancer_tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "service.k8s.aws/stack" = var.gateway_service
  }

  allowed_consumer_accounts = length(var.allowed_consumers) > 0 ? distinct(var.allowed_consumers) : [data.aws_caller_identity.current.account_id]
  allowed_principals        = [for account in local.allowed_consumer_accounts : provider::aws::arn_build(data.aws_partition.current.partition, "iam", "", account, "root")]
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_lbs" "gateway" {
  tags = local.gateway_load_balancer_tags
}

data "aws_lb" "gateway" {
  arn = tolist(data.aws_lbs.gateway.arns)[0]

  lifecycle {
    precondition {
      condition     = length(data.aws_lbs.gateway.arns) == 1
      error_message = length(data.aws_lbs.gateway.arns) == 0 ? "This environment has no internal gateway running. Contact Ryvn support to turn it on, then install again." : "This environment has more than one internal gateway load balancer. Contact Ryvn support."
    }
  }
}

resource "aws_vpc_endpoint_service" "internal_gateway" {
  acceptance_required        = false
  allowed_principals         = local.allowed_principals
  network_load_balancer_arns = [data.aws_lb.gateway.arn]
  supported_ip_address_types = ["ipv4"]

  tags = {
    Name = var.name_prefix
  }
}

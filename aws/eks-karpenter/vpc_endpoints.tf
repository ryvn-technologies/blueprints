# ============================================================================
# S3 gateway endpoint
# ============================================================================
# Routes the cluster's S3 traffic over the AWS backbone instead of through the
# NAT gateway. Gateway endpoints are free: no hourly charge, no per-GB charge.
# Without one, every byte a pod exchanges with a same-region bucket, and every
# ECR image layer (ECR serves layers from S3), pays NAT data-processing fees
# and leaves via the NAT gateway's public IP.
#
# The endpoint is a property of the route table, not of any bucket. AWS installs
# one route per associated table whose destination is the region's S3 prefix
# list, so a single endpoint serves every bucket the cluster reaches, and a
# second endpoint on the same table collides on that route. That is why it lives
# here next to the route tables rather than in a bucket module. GCP and Azure
# carry the same setting on their node subnets (Private Google Access, the
# Microsoft.Storage service endpoint); AWS just models it as a resource.
#
# Ryvn-provisioned VPCs only, attached to the VPC module's private route table.
# A BYO VPC is the customer's own network design: they decide which endpoints it
# carries and how S3 traffic egresses, so Ryvn adds none of its own there, in
# either carve or subnets mode. Opting in under BYO fails the plan rather than
# doing nothing silently; a customer who wants the endpoint creates it from the
# account that owns the network.

locals {
  s3_gateway_endpoint_enabled = coalesce(var.create_s3_gateway_endpoint, !local.byo_enabled)
}

resource "aws_vpc_endpoint" "s3" {
  count = local.s3_gateway_endpoint_enabled ? 1 : 0

  vpc_id            = local.vpc_id
  service_name      = "${data.aws_partition.current.reverse_dns_prefix}.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = flatten(module.vpc[*].private_route_table_ids)

  # Null attaches AWS's default allow-all policy. An endpoint policy can only
  # narrow what IAM and bucket policies already permit, so the default changes
  # the path S3 traffic takes and nothing about who may read or write what.
  policy = var.s3_gateway_endpoint_policy

  tags = merge(local.tags, {
    Name = "ryvn-${var.environment_name}-s3"
  })

  lifecycle {
    precondition {
      condition     = !local.byo_enabled
      error_message = "create_s3_gateway_endpoint cannot be used with existing_vpc_id: Ryvn adds no endpoints of its own to a customer-owned VPC. Create the S3 gateway endpoint from the account that owns the network instead."
    }
  }
}

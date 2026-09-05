resource "aws_route53_zone" "internal" {
  count = var.skip_dns_provisioning ? 0 : 1
  name  = var.internal_root_domain

  force_destroy = true
  vpc {
    vpc_id = local.vpc_id
  }

  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_zone" "public" {
  count = var.skip_dns_provisioning ? 0 : 1
  name  = var.public_root_domain

  force_destroy = true
}

resource "aws_route53_record" "caa" {
  count   = var.skip_dns_provisioning ? 0 : 1
  zone_id = aws_route53_zone.public[0].zone_id
  name    = var.public_root_domain
  type    = "CAA"
  ttl     = 300
  records = [
    "0 issue \"letsencrypt.org\"",
    "0 issue \"amazon.com\"",
    "0 issue \"amazonaws.com\"",
    "0 issue \"amazontrust.com\"",
  ]
}

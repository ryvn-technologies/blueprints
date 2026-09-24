resource "aws_route53_zone" "internal" {
  count = var.skip_dns_provisioning ? 0 : 1
  name  = var.internal_root_domain

  force_destroy = true
  vpc {
    vpc_id = local.vpc_id
  }

  # Renaming the domain replaces the zone. Create the new one first so the
  # external-dns policy can move to it before the old zone is deleted.
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [vpc]
  }
}

resource "aws_route53_zone" "public" {
  count = var.skip_dns_provisioning ? 0 : 1
  name  = var.public_root_domain

  force_destroy = true

  lifecycle {
    create_before_destroy = true
  }
}

# IAM changes take a few seconds to propagate; without this wait external-dns can
# re-create records in the old zone and DeleteHostedZone fails HostedZoneNotEmpty.
resource "time_sleep" "zone_policy_propagation" {
  count           = var.skip_dns_provisioning ? 0 : 1
  create_duration = "60s"

  triggers = {
    internal_zone_id = aws_route53_zone.internal[0].zone_id
    public_zone_id   = aws_route53_zone.public[0].zone_id
  }

  depends_on = [aws_iam_role_policy.external_dns_policy]
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

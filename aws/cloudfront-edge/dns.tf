resource "aws_route53_record" "a" {
  for_each = var.dns.enabled && var.dns.create_ipv4_alias ? toset(local.hostname_keys) : toset([])

  zone_id         = data.aws_route53_zone.public[0].zone_id
  name            = each.value
  type            = "A"
  allow_overwrite = var.dns.allow_overwrite

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = var.dns.evaluate_target_health
  }
}

resource "aws_route53_record" "aaaa" {
  for_each = var.dns.enabled && var.dns.create_ipv6_alias ? toset(local.hostname_keys) : toset([])

  zone_id         = data.aws_route53_zone.public[0].zone_id
  name            = each.value
  type            = "AAAA"
  allow_overwrite = var.dns.allow_overwrite

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = var.dns.evaluate_target_health
  }
}

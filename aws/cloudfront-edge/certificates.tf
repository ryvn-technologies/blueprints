data "aws_route53_zone" "public" {
  count = local.lookup_public_route53_zone ? 1 : 0

  name         = "${local.managed_public_dns_root}."
  private_zone = false
}

resource "aws_acm_certificate" "viewer" {
  count = local.use_managed_viewer_certificate ? 1 : 0

  provider                  = aws.us_east_1
  domain_name               = local.viewer_certificate_primary_hostname
  subject_alternative_names = local.viewer_certificate_sans
  validation_method         = "DNS"
  tags                      = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "viewer_certificate_validation_record" {
  for_each = local.use_managed_viewer_certificate ? local.viewer_certificate_validation_domains : toset([])

  zone_id         = data.aws_route53_zone.public[0].zone_id
  name            = one([for option in aws_acm_certificate.viewer[0].domain_validation_options : option.resource_record_name if option.domain_name == each.value])
  type            = one([for option in aws_acm_certificate.viewer[0].domain_validation_options : option.resource_record_type if option.domain_name == each.value])
  ttl             = 60
  records         = [one([for option in aws_acm_certificate.viewer[0].domain_validation_options : option.resource_record_value if option.domain_name == each.value])]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "viewer" {
  count = local.use_managed_viewer_certificate ? 1 : 0

  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.viewer[0].arn
  validation_record_fqdns = [for record in aws_route53_record.viewer_certificate_validation_record : record.fqdn]
}

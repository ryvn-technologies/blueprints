# Forgets the legacy validation-record address, which can represent the same
# physical apex/wildcard CNAME in multiple Terraform states. Harmless to keep
# indefinitely: it is a no-op for states without the legacy address. Remove
# only once no stored Terraform state still contains
# aws_route53_record.viewer_certificate_validation — installations can skip
# releases, so age alone does not prove every state has migrated.
removed {
  from = aws_route53_record.viewer_certificate_validation

  lifecycle {
    # Keep the CNAME so upgrading one installation cannot interrupt ACM
    # renewal for another installation that has not upgraded yet.
    destroy = false
  }
}

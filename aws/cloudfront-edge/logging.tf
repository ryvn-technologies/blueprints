resource "aws_cloudwatch_log_delivery_source" "cloudfront" {
  count = local.standard_logging_v2_enabled ? 1 : 0

  provider = aws.us_east_1

  log_type     = "ACCESS_LOGS"
  name         = "cloudfront-${aws_cloudfront_distribution.this.id}"
  resource_arn = aws_cloudfront_distribution.this.arn
  tags         = var.tags
}

resource "aws_cloudwatch_log_delivery_destination" "cloudfront" {
  count = local.standard_logging_v2_enabled ? 1 : 0

  provider = aws.us_east_1

  delivery_destination_type = var.standard_logging_v2.delivery_destination_type
  name                      = local.standard_logging_v2_name
  output_format             = var.standard_logging_v2.output_format
  tags                      = var.tags

  delivery_destination_configuration {
    destination_resource_arn = var.standard_logging_v2.destination_resource_arn
  }
}

resource "aws_cloudwatch_log_delivery" "cloudfront" {
  count = local.standard_logging_v2_enabled ? 1 : 0

  provider = aws.us_east_1

  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cloudfront[0].arn
  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront[0].name
  field_delimiter          = var.standard_logging_v2.field_delimiter
  record_fields            = var.standard_logging_v2.record_fields
  tags                     = var.tags

  dynamic "s3_delivery_configuration" {
    for_each = var.standard_logging_v2.s3_delivery_configuration != null ? [var.standard_logging_v2.s3_delivery_configuration] : []

    content {
      enable_hive_compatible_path = s3_delivery_configuration.value.enable_hive_compatible_path
      suffix_path                 = s3_delivery_configuration.value.suffix_path
    }
  }
}

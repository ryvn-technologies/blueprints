resource "aws_cloudfront_monitoring_subscription" "this" {
  count = var.monitoring.enabled ? 1 : 0

  provider        = aws.us_east_1
  distribution_id = aws_cloudfront_distribution.this.id

  monitoring_subscription {
    realtime_metrics_subscription_config {
      realtime_metrics_subscription_status = var.monitoring.realtime_metrics_subscription_status
    }
  }
}

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/test-env-cloud-metrics-reader" }
  }
}

variables {
  name_prefix = "test-env"
  environment = "test"
}

run "emits_the_reader_policy_only" {
  command = apply

  assert {
    condition     = output.policy_arn == "arn:aws:iam::123456789012:policy/test-env-cloud-metrics-reader"
    error_message = "The module must emit the reader policy ARN for the workload-identity role group's policy_arns."
  }

  assert {
    condition     = aws_iam_policy.reader.name == "test-env-cloud-metrics-reader"
    error_message = "The policy name must derive from name_prefix."
  }
}

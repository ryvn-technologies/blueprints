mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test-env-cloud-metrics" }
  }
  mock_resource "aws_eks_pod_identity_association" {
    defaults = { association_id = "a-abcdef1234567890" }
  }
}

variables {
  name_prefix      = "test-env"
  environment      = "test"
  eks_cluster_name = "ryvn-eks-test"
  role_groups = {
    cloud-metrics = {
      associations = {
        collector = { namespace = "observability", service_account = "ryvn-cloud-metrics-alloy" }
      }
      policy_arns = { reader = "arn:aws:iam::123456789012:policy/reader" }
    }
  }
}

run "pod_identity_is_the_default_binding" {
  command = apply

  assert {
    condition     = length(aws_eks_pod_identity_association.this) == 1
    error_message = "The default path must create Pod Identity associations."
  }
}

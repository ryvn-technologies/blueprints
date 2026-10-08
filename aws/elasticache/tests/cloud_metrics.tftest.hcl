mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_resource "aws_elasticache_replication_group" {
    defaults = {
      arn                      = "arn:aws:elasticache:us-east-1:123456789012:replicationgroup:cache-test"
      primary_endpoint_address = "cache-test.example.cache.amazonaws.com"
      reader_endpoint_address  = "cache-test-ro.example.cache.amazonaws.com"
      member_clusters          = ["cache-test-001", "cache-test-002"]
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/ryvn/cache/cache-test" }
  }
}
mock_provider "random" {
  mock_resource "random_id" {
    defaults = { hex = "0a1b2c3d" }
  }
  mock_resource "random_password" {
    defaults = { result = "generated-auth-token-0123456789abcdef" }
  }
}

variables {
  installation_name  = "cache"
  environment        = "test"
  vpc_id             = "vpc-test"
  private_subnet_ids = "subnet-a,subnet-b"
}

run "cloud_metrics_output_emits_the_contract" {
  command = apply

  assert {
    condition     = output.cloud_metrics.schema == 1 && !contains(keys(output.cloud_metrics), "resource_type") && !contains(keys(output.cloud_metrics), "resource_ids") && !contains(keys(output.cloud_metrics), "region")
    error_message = "The cloud_metrics output carries schema plus targets only — family/region/capacity resolve at the adapter, they are never declared."
  }
  assert {
    condition     = output.cloud_metrics.targets.group.cloud_resource_id == aws_elasticache_replication_group.this.arn
    error_message = "The group target must emit the replication group's own ARN."
  }
  assert {
    condition     = output.cloud_metrics.targets.cache-test-001.cloud_resource_id == "arn:aws:elasticache:us-east-1:123456789012:cluster:cache-test-001" && output.cloud_metrics.targets.cache-test-002.cloud_resource_id == "arn:aws:elasticache:us-east-1:123456789012:cluster:cache-test-002"
    error_message = "Each member cluster must be its own target keyed by its member id — positional names re-map when a member leaves."
  }
}

run "environment_tag_opts_the_group_in" {
  command = apply
  variables {
    ryvn_environment_id = "env-abc123"
  }

  assert {
    condition     = aws_elasticache_replication_group.this.tags["ryvn.app/cloud-metrics"] == "env-abc123"
    error_message = "The replication group must carry ryvn.app/cloud-metrics=<env-id> so the collector's tag gate admits it."
  }
}

run "empty_environment_id_leaves_the_group_untagged" {
  command = apply

  assert {
    condition     = !contains(keys(aws_elasticache_replication_group.this.tags), "ryvn.app/cloud-metrics")
    error_message = "Without an environment id the tag must be absent — an empty-valued tag would be an unreadable half-opt-in."
  }
}

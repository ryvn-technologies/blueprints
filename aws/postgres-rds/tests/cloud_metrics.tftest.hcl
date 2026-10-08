mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_db_instance" {
    defaults = {
      master_user_secret = [{
        kms_key_id    = "arn:aws:kms:us-east-1:123456789012:key/example"
        secret_arn    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-example"
        secret_status = "active"
      }]
    }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      resource_id = "db-ABCDEFGHIJKLMNOP"
      address     = "example.us-east-1.rds.amazonaws.com"
      master_user_secret = [{
        kms_key_id    = "arn:aws:kms:us-east-1:123456789012:key/example"
        secret_arn    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-example"
        secret_status = "active"
      }]
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/rds-monitoring" }
  }
}
mock_provider "random" {
  mock_resource "random_id" {
    defaults = { hex = "0a1b2c3d" }
  }
}

variables {
  name_prefix       = "postgres"
  environment       = "test"
  vpc_id            = "vpc-test"
  subnet_ids        = "subnet-a,subnet-b"
  database_username = "postgres"
  database_password = "bootstrap-password"
}

run "cloud_metrics_output_emits_the_contract" {
  command = apply

  assert {
    condition     = output.cloud_metrics.schema == 1 && !contains(keys(output.cloud_metrics), "resource_type") && !contains(keys(output.cloud_metrics), "resource_ids") && !contains(keys(output.cloud_metrics), "region") && !contains(keys(output.cloud_metrics), "allocated_storage_bytes")
    error_message = "The cloud_metrics output carries schema plus targets only — family/region/capacity resolve at the adapter, they are never declared."
  }
  assert {
    condition     = output.cloud_metrics.targets.this.cloud_resource_id == aws_db_instance.this.arn
    error_message = "The single-instance target must emit the instance ARN — service, region, and dimension identity all resolve from it."
  }
}

run "environment_tag_opts_the_instance_in" {
  command = apply
  variables {
    ryvn_environment_id = "env-abc123"
  }

  assert {
    condition     = aws_db_instance.this.tags["ryvn.app/cloud-metrics"] == "env-abc123"
    error_message = "The instance must carry ryvn.app/cloud-metrics=<env-id> so the collector's tag gate admits it."
  }
}

run "empty_environment_id_leaves_the_instance_untagged" {
  command = apply

  assert {
    condition     = !contains(keys(aws_db_instance.this.tags), "ryvn.app/cloud-metrics")
    error_message = "Without an environment id the tag must be absent — an empty-valued tag would be an unreadable half-opt-in."
  }
}

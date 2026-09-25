mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  region       = "us-west-2"
  cluster_name = "ryvn-eks-cp"
  name_prefix  = "cp"
}

override_data {
  target = data.aws_lbs.gateway
  values = {
    arns = ["arn:aws:elasticloadbalancing:us-west-2:111111111111:loadbalancer/net/k8s-ryvnsyst-internal-0123456789/0123456789abcdef"]
  }
}

override_data {
  target = data.aws_lb.gateway
  values = {
    arn  = "arn:aws:elasticloadbalancing:us-west-2:111111111111:loadbalancer/net/k8s-ryvnsyst-internal-0123456789/0123456789abcdef"
    name = "k8s-ryvnsyst-internal-0123456789"
  }
}

run "no_gateway_load_balancer_fails" {
  command = plan

  override_data {
    target = data.aws_lbs.gateway
    values = {
      arns = []
    }
  }

  expect_failures = [
    data.aws_lb.gateway,
  ]
}

run "two_gateway_load_balancers_fail" {
  command = plan

  override_data {
    target = data.aws_lbs.gateway
    values = {
      arns = [
        "arn:aws:elasticloadbalancing:us-west-2:111111111111:loadbalancer/net/k8s-ryvnsyst-internal-0123456789/0123456789abcdef",
        "arn:aws:elasticloadbalancing:us-west-2:111111111111:loadbalancer/net/k8s-ryvnsyst-internal-9876543210/fedcba9876543210",
      ]
    }
  }

  expect_failures = [
    data.aws_lb.gateway,
  ]
}

run "allows_only_its_own_account_by_default" {
  command = plan

  assert {
    condition     = aws_vpc_endpoint_service.internal_gateway.allowed_principals == toset(["arn:aws:iam::111111111111:root"])
    error_message = "An empty allowed_consumers must allow only the environment's own account."
  }
}

run "allowed_consumers_replace_the_own_account" {
  command = plan

  variables {
    allowed_consumers = ["222222222222", "222222222222"]
  }

  assert {
    condition     = aws_vpc_endpoint_service.internal_gateway.allowed_principals == toset(["arn:aws:iam::222222222222:root"])
    error_message = "allowed_consumers must be the endpoint service's allowed principals."
  }
}

run "invalid_consumer_is_rejected" {
  command = plan

  variables {
    allowed_consumers = ["*"]
  }

  expect_failures = [
    var.allowed_consumers,
  ]
}

# One subnet per AZ is what makes private_subnet_ids usable as an explicit
# load-balancer subnet list, so the precondition has to catch a same-AZ pair
# that the "spans >= 2 AZs" check happily accepts.

run "one_subnet_per_az_is_accepted" {
  variables {
    workload_subnets = [
      { id = "subnet-a", availability_zone = "us-east-1a" },
      { id = "subnet-b", availability_zone = "us-east-1b" },
      { id = "subnet-c", availability_zone = "us-east-1c" },
    ]
  }

  assert {
    condition     = output.duplicate_azs == []
    error_message = "one subnet per AZ must be accepted, got duplicates ${join(", ", output.duplicate_azs)}"
  }
}

run "two_subnets_in_one_az_are_rejected" {
  variables {
    workload_subnets = [
      { id = "subnet-a", availability_zone = "us-east-1a" },
      { id = "subnet-a2", availability_zone = "us-east-1a" },
      { id = "subnet-b", availability_zone = "us-east-1b" },
    ]
  }

  assert {
    condition     = output.duplicate_azs == ["us-east-1a"]
    error_message = "the doubled AZ must be reported, got ${jsonencode(output.duplicate_azs)}"
  }

  assert {
    condition     = length(output.azs) == 2
    error_message = "the AZ span check still passes on a same-AZ pair, got ${jsonencode(output.azs)}"
  }
}

run "every_doubled_az_is_named" {
  variables {
    workload_subnets = [
      { id = "subnet-a", availability_zone = "us-east-1a" },
      { id = "subnet-a2", availability_zone = "us-east-1a" },
      { id = "subnet-b", availability_zone = "us-east-1b" },
      { id = "subnet-b2", availability_zone = "us-east-1b" },
    ]
  }

  assert {
    condition     = output.duplicate_azs == ["us-east-1a", "us-east-1b"]
    error_message = "every doubled AZ must be named so the operator sees the whole fix, got ${jsonencode(output.duplicate_azs)}"
  }
}

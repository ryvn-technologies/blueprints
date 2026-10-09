output "policy_arn" {
  description = "ARN of the metrics reader policy — attach through a workload-identity role group (aws-workload-identity policy_arns), never to other subjects"
  value       = aws_iam_policy.reader.arn
}

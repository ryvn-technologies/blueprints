output "role_arn" {
  description = "CodeBuild service role ryvn-init runs as. It is cluster-admin through an EKS access entry."
  value       = aws_iam_role.codebuild_service.arn
}

output "codebuild_project" {
  description = "CodeBuild project that runs the cluster bootstrap."
  value       = aws_codebuild_project.ryvn_init.name
}

output "log_group" {
  description = "CloudWatch log group with the build logs."
  value       = aws_cloudwatch_log_group.codebuild.name
}

output "result_parameter" {
  description = "SSM parameter with the last run's result."
  value       = aws_ssm_parameter.result.name
}

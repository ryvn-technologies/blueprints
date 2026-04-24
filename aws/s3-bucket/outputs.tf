output "bucket_name" {
  description = "Full name of the S3 bucket (including the random suffix)"
  value       = aws_s3_bucket.this.id
}

output "bucket_id" {
  description = "Cloud-native identifier for the bucket (the ARN on AWS)"
  value       = aws_s3_bucket.this.arn
}

output "bucket_domain_name" {
  description = "Regional domain name of the bucket (e.g. my-bucket.s3.us-east-1.amazonaws.com)"
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "region" {
  description = "AWS region where the bucket was created"
  value       = aws_s3_bucket.this.region
}

output "endpoint" {
  description = "S3 endpoint URL for the bucket's region"
  value       = "https://s3.${aws_s3_bucket.this.region}.amazonaws.com"
}

output "role_arn" {
  description = "ARN of the IAM role that grants access to the bucket. Associate via EKS Pod Identity to give pods bucket access."
  value       = aws_iam_role.bucket_access.arn
}

output "role_name" {
  description = "Name of the IAM role that grants access to the bucket"
  value       = aws_iam_role.bucket_access.name
}

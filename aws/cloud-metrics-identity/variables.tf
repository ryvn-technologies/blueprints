variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for the IAM policy name, typically the Ryvn environment name"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. production, staging), applied as a tag"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

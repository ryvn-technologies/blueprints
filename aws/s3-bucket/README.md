# S3 Bucket Module

Provisions an S3 bucket with encryption, public-access blocking, optional versioning and lifecycle rules, optional browser CORS configuration, and a scoped IAM role. Pods get access via EKS Pod Identity -- no static credentials.

## Usage

```hcl
module "bucket" {
  source = "./infra/ryvn-bucket/aws"

  name_prefix             = "my-app"
  environment             = "production"
  cluster_name            = "my-eks-cluster"
  pod_identity_namespace  = "default"
  pod_identity_service_accounts = [
    "my-app",
  ]
}
```

## What's Included

- **Bucket**: Unique name (prefix + random suffix), tagged with `Terraform` and `Environment`
- **Encryption**: SSE-S3 (AES256) always on
- **Public access**: All four public-access-block settings enforced by default (`public_access = false`). The module accepts a `public_access = true` override for direct consumers, but the bucket blueprint does not currently expose it — a cross-cloud `publicAccess` input is tracked in `docs-internal/bucket-blueprint-multicloud-plan.md` §4.
- **CORS**: Optional browser CORS configuration for presigned URL and other direct bucket access flows, modeled as a list of rules so the module can grow to multiple rules without an interface change
- **Versioning**: Off by default, opt-in via `versioning`
- **Lifecycle**: Optional current-version expiration and noncurrent-version expiration
- **IAM role**: Trust policy limited to `pods.eks.amazonaws.com`. Inline policy grants bucket-level `ListBucket`, `GetBucketLocation`, `ListBucketMultipartUploads` and object-level read/write/delete plus multipart cleanup on this bucket only
- **Pod Identity**: One `aws_eks_pod_identity_association` per entry in `pod_identity_service_accounts`, all created in `pod_identity_namespace`. Pods running under those service accounts assume the role automatically via the EKS Pod Identity Agent

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `name_prefix` | Fallback prefix for the bucket name when `bucket_name` is empty | required |
| `bucket_name` | Desired bucket name (random suffix appended automatically) | `""` |
| `environment` | Environment name | required |
| `cluster_name` | EKS cluster name for Pod Identity associations | required |
| `pod_identity_namespace` | Namespace containing the service accounts that should assume the role | `""` |
| `pod_identity_service_accounts` | Service account names in `pod_identity_namespace` that should assume the role | `[]` |
| `aws_region` | AWS region | `"us-east-1"` |
| `versioning` | Enable object versioning | `false` |
| `public_access` | Allow public access (default: all four PAB flags enforced). Not exposed by the bucket blueprint. | `false` |
| `cors_rules` | Browser CORS rules for direct cross-origin bucket requests | `[]` |
| `expiration_days` | Expire current versions after N days (0 = disabled) | `0` |
| `noncurrent_version_expiration_days` | Expire noncurrent versions after N days (0 = disabled; requires versioning) | `0` |
| `deletion_protection` | Single switch. `true` blocks destroy of a non-empty bucket; `false` lets Terraform empty the bucket (all versions) and delete it. | `true` |
| `tags` | Tags for all resources | `{}` |

Each `cors_rules` entry has this shape:

```hcl
cors_rules = [
  {
    allowed_origins = ["https://app.example.com"]
    allowed_methods = ["GET", "PUT", "HEAD"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
]
```

## Outputs

| Name | Description |
|------|-------------|
| `bucket_name` | Full bucket name (prefix + random suffix) |
| `bucket_id` | Cloud-native bucket identifier (ARN on AWS) |
| `bucket_domain_name` | Regional domain name |
| `region` | AWS region |
| `endpoint` | Regional S3 endpoint URL |
| `role_arn` | IAM role ARN (assumed by pods via Pod Identity) |
| `role_name` | IAM role name |

## One-Way Decisions

These cannot be changed after creation: bucket name, bucket region. Once versioning has been enabled it can be suspended but not fully removed.

## Future Additions

- Expose additional Pod Identity customization via blueprint input if per-service namespace support is ever needed
- Unified `publicAccess` mode for hosting public static content (cross-cloud; deferred — see `docs-internal/bucket-blueprint-multicloud-plan.md`)
- SSE-KMS with customer-managed keys
- Lifecycle transitions (to STANDARD_IA, GLACIER, etc.)
- Object lock / retention
- Replication
- Event notifications (SNS/SQS/Lambda)

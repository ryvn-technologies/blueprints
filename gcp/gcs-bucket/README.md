# GCS Bucket Module

Provisions a Cloud Storage bucket with uniform bucket-level access, public access prevention, optional versioning and lifecycle rules, and optional browser CORS configuration. The module writes no IAM bindings: it publishes the bucket name and the recommended object role, and the [workload identity module](../../ryvn-workload-identity/gcp/README.md) binds the workloads' `principal://` members to the bucket.

## Usage

```hcl
module "bucket" {
  source = "./infra/ryvn-bucket/gcp"

  project_id  = "my-project"
  region      = "us-central1"
  name_prefix = "my-app"
  environment = "production"
}

module "workload_identity" {
  source = "./infra/ryvn-workload-identity/gcp"

  project_id = "my-project"
  role_groups = {
    app = {
      associations = { api = { namespace = "prod", service_account = "api" } }
      buckets      = { media = { name = module.bucket.bucket_name, role = module.bucket.iam_role } }
    }
  }
}
```

## What's Included

- **Bucket**: Unique name (prefix + random suffix, sanitized to GCS naming rules), `STANDARD` storage class, labelled with `terraform` and `environment`
- **Encryption**: Google-managed keys (always on)
- **Access control**: `uniform_bucket_level_access = true` so bucket IAM is the only access path; `public_access_prevention = "enforced"` by default (`public_access = false`). The module accepts `public_access = true` for direct consumers, but the bucket blueprint does not expose it.
- **CORS**: Optional browser CORS configuration. GCS has a single `response_header` list, so `allowed_headers` and `expose_headers` are merged
- **Versioning**: Off by default, opt-in via `versioning`
- **Lifecycle**: Optional current-version expiration (`with_state = "LIVE"`) and noncurrent-version expiration (`days_since_noncurrent_time`)

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `project_id` | GCP project | required |
| `region` | Bucket location | `"us-central1"` |
| `name_prefix` | Fallback prefix for the bucket name when `bucket_name` is empty | required |
| `bucket_name` | Desired bucket name (random suffix appended automatically) | `""` |
| `environment` | Environment name | required |
| `versioning` | Enable object versioning | `false` |
| `public_access` | Allow public access (default: public access prevention enforced). Not exposed by the bucket blueprint. | `false` |
| `cors_rules` | Browser CORS rules for direct cross-origin bucket requests | `[]` |
| `expiration_days` | Expire current versions after N days (0 = disabled) | `0` |
| `noncurrent_version_expiration_days` | Expire noncurrent versions after N days (0 = disabled; requires versioning) | `0` |
| `deletion_protection` | `true` blocks destroy of a non-empty bucket; `false` lets Terraform empty the bucket and delete it. | `true` |
| `kms_key_name` | Cloud KMS key (`projects/.../cryptoKeys/...`, same location as the bucket) used as the default encryption key. Empty = Google-managed. The project's GCS service agent is granted `cryptoKeyEncrypterDecrypter` on it | `""` |
| `labels` | Labels for the bucket | `{}` |

`cors_rules` has the same shape as the AWS module.

## Outputs

| Name | Description |
|------|-------------|
| `bucket_name` | Full bucket name (prefix + random suffix). Feed to the workload identity module's `buckets.<key>.name` |
| `bucket_id` | Cloud-native bucket identifier (self link on GCP) |
| `bucket_domain_name` | `<bucket>.storage.googleapis.com` |
| `region` | Bucket location |
| `endpoint` | `https://storage.googleapis.com` |
| `iam_role` | `roles/storage.objectUser`; feed to the workload identity module's `buckets.<key>.role` |
| `encryption_key_id` | The `kms_key_name` in use, or empty |
| `workload_grants` | `[{ kind = "bucket", target = <bucket name>, role }]` — same grant in the cross-cloud list shape every bucket module exposes |

## Prerequisites

- The identity running Terraform can create buckets. Bucket IAM bindings are written by the workload identity module, which needs `storage.buckets.getIamPolicy` and `storage.buckets.setIamPolicy`.

## One-Way Decisions

These cannot be changed after creation: bucket name, bucket location.

## Future Additions

- Unified `publicAccess` mode for hosting public static content (cross-cloud; deferred)
- CMEK with customer-managed keys
- Storage-class transitions (NEARLINE, COLDLINE, ARCHIVE)
- Retention policies / object holds
- Pub/Sub notifications

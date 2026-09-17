# Workload Identity Module (GCP)

Gives Kubernetes workloads access to GCP resources without static credentials. With Workload Identity Federation for GKE the Kubernetes ServiceAccount is already an IAM principal, so this module creates no identity resources at all. It computes each subject's `principal://` member and writes the IAM bindings for it: a role on a bucket (`buckets`) or a role on the project, optionally narrowed by an IAM condition (`project_roles`). Resource modules expose the values to bind (for example the bucket module's `bucket_name` and `iam_role`, or the postgres module's `instance_resource_name` for a condition); pass those, or any role of your own, in. The module never touches ServiceAccounts, pods, or the resources' other settings.

## Usage

```hcl
module "workload_identity" {
  source = "./infra/ryvn-workload-identity/gcp"

  project_id = "my-project"

  role_groups = {
    app = {
      associations = {
        api = {
          namespace       = "prod-gcp"
          service_account = "api"
        }
        worker = {
          namespace       = "prod-gcp"
          service_account = "worker"
        }
      }
      buckets = {
        media = {
          name = module.media_bucket.bucket_name
          role = module.media_bucket.iam_role
        }
      }
      project_roles = {
        cloudsql = {
          role = "roles/cloudsql.instanceUser"
          condition = {
            title      = "app-postgres"
            expression = "resource.name == \"${module.postgres.instance_resource_name}\""
          }
        }
        cloudsql_client = {
          role = "roles/cloudsql.client"
        }
      }
    }
  }
}
```

In a Ryvn blueprint, resolve the subjects from the installations themselves rather than typing names:

```yaml
project_id: '{{ .ryvn.env.provider.gcp.projectId }}'
role_groups:
  app:
    associations:
      worker:
        namespace:          '{{ (serviceInstallation "worker").namespace }}'
        service_account:    '{{ (serviceInstallation "worker").name }}'
    buckets:
      media:
        name: '{{ (blueprintInstallation "media").outputs.bucketName }}'
        role: '{{ (blueprintInstallation "media").outputs.iamRole }}'
```

Ryvn's web-server and job charts name the ServiceAccount after the installation, so the installation name is the ServiceAccount name.

## What's Included

- **Principal identifiers**: `principal://iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/<project>.svc.id.goog/subject/ns/<namespace>/sa/<service account>` per subject. Ryvn's pre-deploy hook runs as `<service_account>-pre-deploy`; list it as its own association when the hook needs the same access.
- **Bucket bindings** (`buckets`): one non-authoritative `google_storage_bucket_iam_member` per entry and subject, binding `role` on the bucket `name`.
- **Project bindings** (`project_roles`): one non-authoritative `google_project_iam_member` per entry and subject on `project_id`, carrying the optional IAM `condition`. This is how services without resource-level IAM are granted: `roles/cloudsql.instanceUser` conditioned on `resource.name == "projects/<p>/instances/<i>"` for Cloud SQL, `roles/redis.dbConnectionUser` conditioned on its cluster for Memorystore. Without a condition the role applies project-wide.

Keys under `buckets` and `project_roles` are yours; they only name the binding in state, so keep them stable.

Nothing needs to be annotated. The GKE metadata server authenticates the pod as its ServiceAccount and IAM evaluates the binding directly.

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `project_id` | Project owning the cluster and buckets | required |
| `role_groups` | Map of groups; see the shape above | required |
| `project_number` | Project number; resolved from `project_id` when empty | `""` |
| `region` | Provider default region; nothing regional is created | `"us-central1"` |
| `name_prefix` | Accepted for parity with the other clouds; unused | `""` |
| `environment` | Accepted for parity with the other clouds; unused | `""` |

## Outputs

| Name | Description |
|------|-------------|
| `principals` | `[principal:// member, ...]` per group. Same output shape as the AWS and Azure modules |
| `members` | `principal://` member per subject |
| `project_number` | Project number used in the identifiers |

## Prerequisites

- Workload Identity Federation is enabled on the cluster and node pools run the GKE metadata server. Ryvn-provisioned clusters have both.
- The identity running Terraform holds `storage.buckets.getIamPolicy` and `storage.buckets.setIamPolicy` on the granted buckets, `resourcemanager.projects.getIamPolicy` and `resourcemanager.projects.setIamPolicy` if any `project_roles` are used, and `resourcemanager.projects.get` unless `project_number` is supplied.

## Notes

- **No identity resources.** There is no service account to delete, rotate, or hit a quota on. Removing a group removes only its bindings.
- **One group per ServiceAccount.** The variable validation rejects a namespace/ServiceAccount pair that appears in more than one association, matching the AWS and Azure modules.
- **Bindings accumulate.** Any number of bindings can target the same subject; there is no one-per-ServiceAccount limit on GCP. Resources without a dedicated input (Secret Manager, Pub/Sub, KMS) can be bound to `principals.<group>` outside the module with the matching `google_*_iam_member`.
- **Conditions are part of the binding.** Changing a project role's condition replaces the binding; the old one is removed and the new one added in the same apply.
- **Namespace-wide grants** are possible with a `principalSet://.../namespace/<ns>` member but are not exposed here; list the subjects explicitly.
- **Ordering.** Resources must exist before their bindings. In a Ryvn blueprint the output references handle this.

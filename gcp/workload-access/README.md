# Workload Access Module (GCP)

Grants Kubernetes workloads access to GCP resources that other modules provisioned. It creates no identity resources: with Workload Identity Federation for GKE the Kubernetes ServiceAccount is already an IAM principal, so the module computes each subject's `principal://` member and writes IAM bindings for it. Resource modules stay IAM-free and publish what they can grant through a `workload_grants` output; this module applies it.

Today the module handles bucket grants (`google_storage_bucket_iam_member`). Project-scoped grants for Cloud SQL / Memorystore and the AWS (Pod Identity) and Azure (federated credential) counterparts are the intended next steps, so that no resource module needs its own access variables.

## Usage

```hcl
module "loki_bucket" {
  source = "./infra/ryvn-bucket/gcp"

  project_id  = "my-project"
  region      = "us-west1"
  name_prefix = "loki"
  environment = "production"
}

module "loki_access" {
  source = "./infra/ryvn-workload-access/gcp"

  project_id       = "my-project"
  namespace        = "observability"
  service_accounts = ["loki"]
  grants           = module.loki_bucket.workload_grants
}
```

In a Ryvn blueprint the module runs as a Terraform service child next to the `bucket` blueprint child it grants access to. The bucket's `workloadGrants` output is already the JSON shape `grants` expects:

```yaml
- blueprint: bucket
  alias: loki-bucket
  name: '{{ ParentInstallationName }}-loki'

- service: gcp-workload-access
  alias: loki-access
  name: '{{ ParentInstallationName }}-loki-access'
  provisionsInfrastructure: true
  condition: '{{ eq EnvironmentProviderType "gcp" }}'
  config: |
    project_id: '{{ .ryvn.env.provider.gcp.projectId }}'
    namespace: '{{ (serviceInstallation "loki").namespace }}'
    service_accounts: ['{{ (serviceInstallation "loki").name }}']
    grants: {{ (blueprintInstallation "loki-bucket").outputs.workloadGrants }}
```

Ryvn's web-server and job charts name the ServiceAccount after the installation, so the installation name is the ServiceAccount name.

## What's Included

- **Principal identifiers**: `principal://iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/<project>.svc.id.goog/subject/ns/<namespace>/sa/<service account>` per subject. With `include_pre_deploy = true` (the default) the `<service account>-pre-deploy` ServiceAccount used by Ryvn's pre-deploy hook is covered as well.
- **Bucket grants** (`kind = "bucket"`): one non-authoritative `google_storage_bucket_iam_member` per subject and grant, on the bucket named by `target`, with the grant's `role`.

A grant is `{ kind, target, role }`. Resource modules emit it; callers pass it through and never write one by hand.

Nothing needs to be annotated. The GKE metadata server authenticates the pod as its ServiceAccount and IAM evaluates the binding directly.

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `project_id` | Project owning the cluster and the granted resources | required |
| `namespace` | Kubernetes namespace of the subjects | required |
| `service_accounts` | ServiceAccount names in `namespace` | required |
| `grants` | `[{ kind, target, role }]`, pass a resource module's `workload_grants` through | required |
| `include_pre_deploy` | Also grant `<name>-pre-deploy` for each ServiceAccount | `true` |
| `project_number` | Project number; resolved from `project_id` when empty | `""` |
| `region` | Provider default region; nothing regional is created | `"us-central1"` |

## Outputs

| Name | Description |
|------|-------------|
| `members` | `principal://` member per subject |
| `bucket_bindings` | `[{ bucket, role, member }]` written by this module |
| `project_number` | Project number used in the identifiers |

## Prerequisites

- Workload Identity Federation is enabled on the cluster and node pools run the GKE metadata server. Ryvn-provisioned clusters have both.
- The identity running Terraform holds `storage.buckets.getIamPolicy` and `storage.buckets.setIamPolicy` on the granted buckets, and `resourcemanager.projects.get` unless `project_number` is supplied. Ryvn's GCP agent role includes these.

## Notes

- **No identity resources.** There is no service account to delete, rotate, or hit a quota on. Destroying the installation removes only its bindings.
- **Bindings accumulate.** Several installations of this module can target the same bucket or the same subject; each manages only the members it wrote.
- **Ordering.** Buckets must exist before their bindings. In a Ryvn blueprint the output reference to the bucket child handles this.

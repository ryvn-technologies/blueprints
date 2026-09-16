# Ryvn Managed Registry (GCP Artifact Registry)

Provisions a Docker-format Artifact Registry repository that acts as an
environment-scoped mirror for Ryvn-built container images and OCI Helm charts.

## Identity model

| Principal | How it authenticates | Grant |
|-----------|----------------------|-------|
| Artifact copier (`push_service_accounts` in `push_namespace`) | Workload Identity Federation for GKE (`principal://...svc.id.goog/subject/ns/<ns>/sa/<sa>`) | `roles/artifactregistry.writer` on the repository |
| Cluster nodes (kubelet) | Node service account | `roles/artifactregistry.reader` on the repository |
| Ryvn hub | GoogleArtifactRegistry registry definition (no credentials stored) | — |

No service-account keys are created and no secrets are emitted as outputs.

Node service accounts are discovered from `cluster_name` when it is set and
merged with `node_service_accounts`. For attached clusters (not provisioned by
Ryvn) leave `cluster_name` empty and pass `node_service_accounts` explicitly. Provisioning fails when no node identity can
be resolved unless `require_node_pull_grant = false`.

## Executor permissions

The module enables `artifactregistry.googleapis.com` and manages the repository
and its IAM. The identity running Terraform needs
`serviceusage.services.enable`, `serviceusage.services.get`,
`serviceusage.operations.get`, and
`artifactregistry.repositories.{create,delete,get,list,update,getIamPolicy,setIamPolicy}`.
The `gke-provision` module's default agent role includes these; environments
that override it with `terraform_executor_policies` must add them.

## Retention

No cleanup policies are configured; mirrored artifacts are kept until removed
by an operator.

## Outputs

`registry_host`, `repository_id`, `repository_name`, `destination_base`, `path_prefix`,
`region`, `project_id`, `registry_definition` (API-shaped), `push_identity`,
`pull_identity`.

## Testing

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

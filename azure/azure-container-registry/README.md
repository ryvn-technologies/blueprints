# Ryvn Managed Registry (Azure Container Registry)

Provisions an Azure Container Registry that acts as an environment-scoped mirror
for Ryvn-built container images and OCI Helm charts. Admin credentials and
anonymous pull are disabled.

## Identity model

| Principal | How it authenticates | Grant |
|-----------|----------------------|-------|
| Artifact copier (`push_service_accounts` in `push_namespace`) | Workload Identity: user-assigned identity with a federated credential per service account | `AcrPush` on the registry |
| Cluster nodes (kubelet) | Kubelet managed identity (`node_principal_ids`) | `AcrPull` on the registry |
| Ryvn hub | Maps the plain registry outputs to a dedicated `azureContainerRegistry` record (login server, resource group, location) authenticated through cluster identity | — |

The Ryvn agent's existing managed identity object ids can be granted `AcrPull`
with `pull_principal_ids`. Azure does not create a new agent identity;
`pull_namespace` and `pull_service_accounts` are informational output fields.

No registry passwords, tokens or scope maps are created and no secrets are
emitted as outputs.

The module emits `registry_type` (`acr`), `registry_host`, `region`,
`registry_id`, and `resource_group_name`. The hub maps these plain outputs to a
registry record; ACR has no dedicated Registry API type, so it is represented
as a generic container registry with the `azureContainerRegistry` subtype and
cluster-default pull credentials.

When `cluster_name` is set, the kubelet identity and OIDC issuer are read from
the AKS cluster. Attached clusters must pass `node_principal_ids` and
`oidc_issuer_url` explicitly. Provisioning fails when either cannot be resolved
(node identity can be waived with `require_node_pull_grant = false`).

## Retention

No retention policy is configured; mirrored artifacts are kept until removed
by an operator.

## Testing

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

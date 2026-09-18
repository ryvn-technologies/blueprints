# Ryvn Managed Registry (AWS ECR)

Provisions the IAM surface for an environment-scoped ECR mirror of Ryvn-built
container images and OCI Helm charts. ECR needs one repository per image name,
so this module reserves a repository namespace (`<name>-<suffix>/`) and lets
the artifact copier create repositories lazily beneath it; every grant is
scoped to that prefix.

## Identity model

| Principal | How it authenticates | Grant |
|-----------|----------------------|-------|
| Artifact copier (`push_service_accounts` in `push_namespace`) | EKS Pod Identity (`aws_iam_role.push`) | Create repositories, push and pull under the prefix |
| Cluster nodes (kubelet) | Node instance role (`node_role_names`) | Read-only under the prefix (`aws_iam_policy.pull`) |
| Ryvn agent | Its own IAM role (`pull_role_arns`, discovered from the environment's `ryvn_agent_role_arn`) | Read-only under the prefix |
| Ryvn hub (optional) | Assumes `aws_iam_role.hub_read` from `hub_principal_arn` | Read-only under the prefix |

The read-only policy is attached to the Ryvn agent's existing IAM role through
`pull_role_arns`; each mirror attaches its own policy, so multiple mirrors can
share a cluster without competing for a Pod Identity association.

No IAM users or access keys are created and no secrets are emitted as outputs.

Node roles are discovered from EKS managed node groups when `cluster_name` is
set and merged with `node_role_names`. Karpenter node roles and attached
clusters must be passed explicitly. Provisioning fails when no node role can be resolved unless
`require_node_pull_grant = false`. Pod identity associations are only created
when `cluster_name` is set; attached clusters bind `push_identity.roleArn`
themselves.

## Registry definition

`registry_definition` follows the Ryvn registry API:

* with `hub_principal_arn`: `elasticContainerRegistry` + `assumeRole`
  credentials pointing at the hub read role;
* otherwise: `genericContainerRegistry` + `clusterDefault` credentials (nodes
  pull through their instance role).

## Retention

No lifecycle policies are configured and neither identity may delete images or
repositories; mirrored artifacts are kept until removed by an operator.

## Testing

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

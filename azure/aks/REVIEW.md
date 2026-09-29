# Review Guidelines

## Provisioner permissions

Environments provisioned by this module run under the least-privilege role in
`permissions/provisioner-role.json`. A change that makes Terraform call a new cloud API
must grant it in the same PR; otherwise every environment on that role fails its
next plan/apply with `AuthorizationFailed`.

Flag the PR if `permissions/provisioner-role.json` is unchanged and it:

- Adds a `resource` or `data` block of a type not already used in this module.
- Sets a previously unset argument on an upstream module or provider resource.
  Many arguments are backed by separate child resources with their own actions.
  Example: AKS `maintenance_window_*` on `azurerm_kubernetes_cluster` is managed as child `managedClusters/maintenanceConfigurations` and needs `.../maintenanceConfigurations/read|write|delete`.
- Bumps an upstream module or provider version (new versions may read extra
  sub-resources on refresh).
- Changes a variable default from `null` to a value, which enables a code path for
  every existing environment.

Reads count too: refresh runs on every plan, so the read/get/describe action is
required even for a no-op.

When the role changes, also update the action count and table in `permissions/README.md` and the assertions in `permissions/permissions_test.go`. The PR description should note that existing
accounts on the narrowed role must re-run the setup script before applying.

# Review Guidelines

## Public blueprint confidentiality

This entire directory is copied to public blueprints for both main and prerelease,
including docs, comments, code, examples, tests, fixtures, scripts and filenames.
Flag customer/prospect names or identifying details (domains, account/project/
subscription/tenant/environment IDs, emails, resource names, support/evidence links
and narratives) as a **high-priority confidentiality finding requiring sanitization
before merge**, unless explicit publication authorization exists. Removing credentials
alone is not sanitization. Use synthetic examples such as `example.invalid` and keep
customer evidence outside exported trees; apply this to public PR descriptions,
commits and review comments too. Preserve real validation caveats and legitimate
technical terms such as TLS handshake. Cite only path/line and category, redacting
sensitive paths and never quoting sensitive values. This is agent review guidance,
not a deterministic CI gate or guaranteed detection.

## Provisioner permissions

Environments provisioned by this module run under the least-privilege role in
`permissions/cloudformation-access-role-byo-vpc.json`. A change that makes Terraform call a new cloud API
must grant it in the same PR; otherwise every environment on that role fails its
next plan/apply with `AccessDenied` / `UnauthorizedOperation`.

Flag the PR if `permissions/cloudformation-access-role-byo-vpc.json` is unchanged and it:

- Adds a `resource` or `data` block of a type not already used in this module.
- Sets a previously unset argument on an upstream module or provider resource.
  Many arguments are backed by separate child resources with their own actions.
- Bumps an upstream module or provider version (new versions may read extra
  sub-resources on refresh).
- Changes a variable default from `null` to a value, which enables a code path for
  every existing environment.

Reads count too: refresh runs on every plan, so the read/get/describe action is
required even for a no-op. The PR description should note that existing
accounts on the narrowed role must re-run the setup script before applying.

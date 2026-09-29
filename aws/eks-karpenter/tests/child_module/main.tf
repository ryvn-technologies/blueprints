# Consumes the production root as a child module. `terraform init` here fails
# on anything root-only in the module (import/moved-with-for_each, backend,
# cloud blocks), which the root's own tests never exercise. Run:
#
#   cd tests/child_module && terraform init -backend=false && terraform validate
#
# The nested root keeps its own provider block, so this is init/validate only;
# nothing is planned against AWS.
variable "region" {
  type    = string
  default = "us-east-1"
}

module "ryvn_eks" {
  source = "../.."

  region               = var.region
  environment_name     = "child-module-check"
  account_id           = "123456789012"
  internal_root_domain = "internal.example.com"
  public_root_domain   = "example.com"
}

output "egress_firewall" {
  value = module.ryvn_eks.egress_firewall
}

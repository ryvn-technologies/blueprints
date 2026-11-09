#!/usr/bin/env bash
# Apply only bookkeeping records offline, then destroy them through a saved
# plan without forgetting state. AWS resources are never created.
set -euo pipefail
cd "$(dirname "$0")/lifecycle"
rm -rf .terraform terraform.tfstate terraform.tfstate*.backup .terraform.lock.hcl destroy.tfplan
trap 'rm -rf .terraform terraform.tfstate terraform.tfstate*.backup .terraform.lock.hcl destroy.tfplan' EXIT

TARGETS=(-target=module.groups.terraform_data.contract -target=module.groups.terraform_data.geometry)
A='{ name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b"] }'
B='{ name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a"] }'
B_RETIRED='{ name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a"], retired = true }'
RENAMED='{ name = "api_clients_v2", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b"] }'

apply() { terraform apply -auto-approve -input=false -no-color "${TARGETS[@]}" -var "groups=[$1]" >/dev/null; }
expect_allowed() {
  terraform plan -input=false -no-color "${TARGETS[@]}" -var "groups=[$2]" >/dev/null
  echo "ok: $1 allowed for plan review"
}

terraform init -input=false -no-color >/dev/null
apply "$A";             echo "ok: initial apply"
expect_allowed "remove the only group" ""
expect_allowed "rename the only group" "$RENAMED"
apply "$A, $B";         echo "ok: append still applies"
apply "$A, $B_RETIRED"; echo "ok: retirement still applies"
expect_allowed "delete a trailing retired tombstone" "$A"
expect_allowed "clear the list" ""
terraform state list | grep -q 'terraform_data.geometry\["small_jobs"\]' || { echo "FAIL: tombstone record missing"; exit 1; }

terraform plan -destroy -input=false -no-color -var "groups=[$A, $B_RETIRED]" -out=destroy.tfplan >/dev/null
echo "ok: full destroy plan succeeds with active and retired records in state"
terraform apply -input=false -no-color destroy.tfplan >/dev/null
if [[ -n "$(terraform state list)" ]]; then
  echo "FAIL: destroy left resources in state"; exit 1
fi
echo "ok: saved destroy plan removes all records without state surgery"
echo "PASS"

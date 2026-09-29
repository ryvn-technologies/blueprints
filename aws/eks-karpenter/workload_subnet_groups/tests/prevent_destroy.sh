#!/usr/bin/env bash
# Offline, Terraform-only check of the allocation ledger's prevent_destroy
# behaviour (terraform test cannot assert on that error). Applies just the
# module's terraform_data records in tests/prevent_destroy, then verifies:
#   - removing the only group, renaming a group, deleting a retired tombstone
#     and clearing the list are all rejected;
#   - append and retirement still apply;
#   - a plain destroy plan is blocked; after deliberately forgetting ONLY the
#     geometry records (terraform state rm) a fresh destroy plan succeeds.
set -euo pipefail
cd "$(dirname "$0")/prevent_destroy"
rm -rf .terraform terraform.tfstate terraform.tfstate*.backup .terraform.lock.hcl
trap 'rm -rf .terraform terraform.tfstate terraform.tfstate*.backup .terraform.lock.hcl' EXIT

TARGETS=(-target=module.groups.terraform_data.contract -target=module.groups.terraform_data.geometry)
A='{ name = "api_clients", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b"] }'
B='{ name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a"] }'
B_RETIRED='{ name = "small_jobs", ipv4_prefix_length = 26, availability_zones = ["us-east-1a"], retired = true }'
RENAMED='{ name = "api_clients_v2", ipv4_prefix_length = 24, availability_zones = ["us-east-1a", "us-east-1b"] }'

apply() { terraform apply -auto-approve -input=false -no-color "${TARGETS[@]}" -var "groups=[$1]" >/dev/null; }
expect_blocked() { # $1 label, $2 groups
  local out
  if out=$(terraform plan -input=false -no-color "${TARGETS[@]}" -var "groups=[$2]" 2>&1); then
    echo "FAIL: $1 was not rejected"; echo "$out"; exit 1
  fi
  grep -q "lifecycle.prevent_destroy" <<<"$out" || { echo "FAIL: $1 failed for another reason"; echo "$out"; exit 1; }
  echo "ok: $1 rejected by prevent_destroy"
}

terraform init -input=false -no-color >/dev/null
apply "$A";               echo "ok: initial apply"
expect_blocked "remove the only group" ""
expect_blocked "rename a group" "$RENAMED"
apply "$A, $B";           echo "ok: append still applies"
apply "$A, $B_RETIRED";   echo "ok: retirement still applies"
expect_blocked "delete a retired tombstone" "$A"
expect_blocked "clear the list" ""
terraform state list | grep -q 'terraform_data.geometry\["small_jobs"\]' || { echo "FAIL: tombstone record missing"; exit 1; }

if out=$(terraform plan -destroy -input=false -no-color "${TARGETS[@]}" -var "groups=[$A, $B_RETIRED]" 2>&1); then
  echo "FAIL: destroy plan was not blocked"; echo "$out"; exit 1
fi
grep -q "lifecycle.prevent_destroy" <<<"$out"; echo "ok: destroy plan blocked while records exist"

# Deliberate teardown bookkeeping: forget ONLY the geometry records.
while read -r address; do terraform state rm -no-color "$address" >/dev/null; done < <(terraform state list | grep 'terraform_data.geometry\[')
terraform plan -destroy -input=false -no-color "${TARGETS[@]}" -var "groups=[$A, $B_RETIRED]" >/dev/null
echo "ok: fresh destroy plan succeeds after forgetting geometry records only"
echo "PASS"

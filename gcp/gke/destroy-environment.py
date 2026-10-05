#!/usr/bin/env python3
"""Explicit full-environment teardown; never used for provisioning or updates."""

import argparse
from contextlib import contextmanager
import json
import os
import stat
from pathlib import Path
import subprocess
import sys


def terraform(directory, *args, pass_fds=()):
    return subprocess.check_output(
        ["terraform", f"-chdir={directory}", *args], text=True, pass_fds=pass_fds
    )


@contextmanager
def private_evidence_directory(path):
    path = Path(os.path.abspath(path))
    descriptor = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in path.parts[1:-1]:
            validate_evidence_parent(descriptor)
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        validate_evidence_parent(descriptor)
        os.mkdir(path.name, mode=0o700, dir_fd=descriptor)
        child = os.open(path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=descriptor)
        os.close(descriptor)
        descriptor = child
        os.fchmod(descriptor, 0o700)
        yield descriptor
    finally:
        os.close(descriptor)


def validate_evidence_parent(descriptor):
    metadata = os.fstat(descriptor)
    if metadata.st_uid not in {0, os.getuid()} or (
        metadata.st_mode & 0o022 and not metadata.st_mode & stat.S_ISVTX
    ):
        raise ValueError("Evidence ancestors must be owned by root/current user and not group/world writable (except sticky directories).")


def write_private(descriptor, name, content):
    file_descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                              0o600, dir_fd=descriptor)
    with os.fdopen(file_descriptor, "w") as stream:
        stream.write(content)


def validate_destroy_plan(plan):
    changes = [r for r in plan.get("resource_changes", []) if r["mode"] == "managed"]
    if not changes or not any(r["change"]["actions"] == ["delete"] for r in changes):
        raise ValueError("Refusing an empty destroy plan.")
    if any(r["change"]["actions"] != ["delete"] for r in changes):
        raise ValueError("Refusing a plan containing creates, updates, replacements or retained managed resources.")


def destroy(directory, evidence, network_id, var_files):
    directory = Path(directory).resolve()
    evidence = Path(os.path.abspath(evidence))
    if evidence == directory or directory in evidence.parents:
        raise ValueError("Evidence must be outside the module checkout (contains private state).")
    with private_evidence_directory(evidence) as descriptor:
        destroy_with_evidence(directory, descriptor, network_id, var_files)


def destroy_with_evidence(directory, descriptor, network_id, var_files):
    state = terraform(directory, "state", "pull")
    inventory = json.loads(state)
    actual_network = inventory.get("outputs", {}).get("vpc", {}).get("value", {}).get("id")
    if not network_id or actual_network != network_id:
        raise ValueError("Confirmation does not match the applied vpc.id output.")
    resources = inventory.get("resources", [])
    guarded = [r for r in resources if r.get("mode") == "managed" and
               (r["type"], r["name"]) == ("terraform_data", "additional_subnet_geometry")]
    if any(r.get("module") for r in guarded):
        raise ValueError("Only standalone gke-provision roots are supported, not wrapped child modules.")
    if not guarded:
        raise ValueError("No guarded allocation records; use ordinary Terraform destroy instead.")
    write_private(descriptor, "state-before.json", state)
    override = directory / "allocation_teardown_override.tf"
    plan_file = Path(f"/proc/self/fd/{descriptor}/destroy.tfplan")
    write_private(descriptor, "destroy.tfplan", "")
    stream = override.open("x")
    try:
        with stream:
            for resource in guarded:
                stream.write(f'resource "{resource["type"]}" "{resource["name"]}" {{\n'
                             '  lifecycle { prevent_destroy = false }\n}\n')
        terraform(directory, "plan", "-destroy", "-input=false", "-lock-timeout=5m",
                  f"-out={plan_file}", *[f"-var-file={p}" for p in var_files], pass_fds=(descriptor,))
        plan = json.loads(terraform(directory, "show", "-json", str(plan_file), pass_fds=(descriptor,)))
        validate_destroy_plan(plan)
        write_private(descriptor, "destroy-plan.json", json.dumps(plan))
        # Only the reviewed, saved destroy plan is applied. No config-based apply.
        terraform(directory, "apply", "-input=false", "-lock-timeout=5m", str(plan_file), pass_fds=(descriptor,))
        remaining = json.loads(terraform(directory, "state", "pull"))
        write_private(descriptor, "state-after.json", json.dumps(remaining))
        if any(r["mode"] == "managed" and r.get("instances") for r in remaining.get("resources", [])):
            raise ValueError("Managed state remains; retain evidence and reconcile before any new apply.")
    finally:
        override.unlink()
    print("Terraform full destroy completed with an explicit allocation lifecycle override.")
    print("This is not an unchanged-module destroy or proof of cloud inventory cleanup.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True)
    parser.add_argument("--evidence-directory", required=True)
    parser.add_argument("--confirm-network-id", required=True,
                        help="Exact applied vpc.id; authorizes destruction of ALL resources in this state.")
    parser.add_argument("--var-file", action="append", default=[])
    args = parser.parse_args()
    os.umask(0o077)
    try:
        destroy(args.directory, args.evidence_directory, args.confirm_network_id, args.var_file)
    except (ValueError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Teardown stopped: {error}. Preserve private evidence; normal guards remain in source.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

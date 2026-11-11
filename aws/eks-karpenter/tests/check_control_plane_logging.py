#!/usr/bin/env python3
"""Check mocked EKS resource plans as well as the Terraform test assertions."""

import json
from pathlib import Path
import subprocess
import sys


expected = {
    "default_preserves_all_control_plane_logs": {
        "api", "audit", "authenticator", "controllerManager", "scheduler"
    },
    "audit_free_environment_reports_selected_logs": {
        "api", "authenticator", "controllerManager", "scheduler"
    },
}
seen = set()
failures = []
diagnostics = []

# Child-module resources are not directly addressable in tftest assertions.
with subprocess.Popen(
    ["terraform", "test", "-filter=tests/control_plane_logging.tftest.hcl", "-json", "-verbose"],
    cwd=Path(__file__).resolve().parent.parent,
    stdout=subprocess.PIPE,
    text=True,
) as process:
    for line in process.stdout:
        event = json.loads(line)
        if event.get("@level") == "error":
            diagnostics.append(event.get("diagnostic", event.get("@message")))
        run = event.get("@testrun")
        if "test_plan" not in event or run not in expected:
            continue
        clusters = [
            resource["change"]["after"].get("enabled_cluster_log_types", [])
            for resource in event["test_plan"]["resource_changes"]
            if resource["address"] == "module.eks.aws_eks_cluster.this[0]"
        ]
        seen.add(run)
        if len(clusters) != 1 or set(clusters[0]) != expected[run]:
            failures.append(f"{run}: unexpected planned EKS log types: {clusters}")
        else:
            print(f"PASS: {run}: EKS exports {sorted(clusters[0])}")
    result = process.wait()

if result:
    for diagnostic in diagnostics:
        print(diagnostic, file=sys.stderr)
if seen != set(expected):
    failures.append(f"Missing EKS resource plans: {sorted(set(expected) - seen)}")
for failure in failures:
    print(f"FAIL: {failure}", file=sys.stderr)
sys.exit(result or bool(failures))

#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
terraform -chdir="$module_dir" test -filter=tests/node_pool_upgrade_settings.tftest.hcl -verbose -json |
  jq -se '
    [.[] | select(.type == "test_plan" and (.["@testrun"] | startswith("reject_") | not)) |
      {key: .["@testrun"], value: .test_plan.resource_changes}] | from_entries as $plans |
    def pool_change($run; $name):
      $plans[$run][] | select(.address ==
        ("module.aks.azurerm_kubernetes_cluster_node_pool.node_pool_create_before_destroy[\"" + $name + "\"]")) |
      .change;
    def pool($run; $name): pool_change($run; $name).after;
    def system_pool($run):
      $plans[$run][] | select(.address == "module.aks.azurerm_kubernetes_cluster.main") |
      .change | {after: .after.default_node_pool[0], after_unknown: .after_unknown.default_node_pool[0]};
    def settings($run; $name): pool($run; $name).upgrade_settings;
    def require($condition; $message): if $condition then . else error($message) end;
    require(($plans | keys) == ["explicit_surge", "explicit_unavailable", "null_settings", "omitted_settings"];
      "Expected all four resource plans") |
    require(all(["omitted_settings", "null_settings"][];
      settings(.; "application") == [{
        max_surge: "33%", max_unavailable: null, drain_timeout_in_minutes: 30,
        node_soak_duration_in_minutes: 0, undrainable_node_behavior: null}] and
      settings(.; "sandbox") == [{
        max_surge: "33%", max_unavailable: null, drain_timeout_in_minutes: null,
        node_soak_duration_in_minutes: null, undrainable_node_behavior: null}]);
      "Omitted/null settings did not use the default upgrade settings") |
    require(all(["omitted_settings", "null_settings"][];
      system_pool(.).after.upgrade_settings[0].max_surge == "33%");
      "System pool surge is not 33%") |
    require(system_pool("omitted_settings").after.node_count == null and
      system_pool("omitted_settings").after_unknown.node_count == true and
      all(["application", "sandbox"][];
        pool("omitted_settings"; .).node_count == null and
        pool_change("omitted_settings"; .).after_unknown.node_count == true);
      "A pool node_count is set by Terraform") |
    require(pool("omitted_settings"; "application").auto_scaling_enabled == true and
      pool("omitted_settings"; "application").min_count == 1 and
      pool("omitted_settings"; "application").max_count == 4;
      "Application autoscaling bounds changed") |
    require(settings("explicit_surge"; "application")[0] == {
      max_surge: "20%", max_unavailable: null, drain_timeout_in_minutes: 45,
      node_soak_duration_in_minutes: 10, undrainable_node_behavior: "Cordon"} and
      settings("explicit_surge"; "sandbox")[0].max_surge == "10%";
      "Explicit surge fields were not passed through") |
    require(all(["application", "sandbox"][];
      settings("explicit_unavailable"; .)[0].max_surge == null and
      settings("explicit_unavailable"; .)[0].max_unavailable == "1") and
      settings("explicit_unavailable"; "application")[0].drain_timeout_in_minutes == null and
      settings("explicit_unavailable"; "application")[0].node_soak_duration_in_minutes == null and
      settings("explicit_unavailable"; "application")[0].undrainable_node_behavior == null and
      settings("explicit_unavailable"; "sandbox")[0].drain_timeout_in_minutes == 60 and
      settings("explicit_unavailable"; "sandbox")[0].node_soak_duration_in_minutes == 8 and
      settings("explicit_unavailable"; "sandbox")[0].undrainable_node_behavior == "Cordon";
      "Explicit unavailable inherited application defaults or lost supplied fields") |
    "Node-pool resource plan assertions passed"
  '

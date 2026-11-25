#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
terraform -chdir="$module_dir" test -filter=tests/cluster_version_upgrade.tftest.hcl -verbose -json |
  jq -se '
    def require($condition; $message): if $condition then . else error($message) end;
    def pools: ["system", "application", "sandbox"];
    ([.[] | select(.type == "test_run" and .test_run.status != null) | .test_run.status] | all(. == "pass")) as $passed |
    ([.[] | select(.type == "test_state" and .["@testrun"] == "apply_current_version")][0].test_state.root_module.child_modules[] |
      select(.address == "module.aks") | .resources | map({key: .address, value: .values}) | from_entries) as $state |
    ([.[] | select(.type == "test_plan") | {key: .["@testrun"], value: .test_plan.resource_changes}] | from_entries) as $plans |
    def pool_version($name):
      if $name == "system" then
        $state["module.aks.azurerm_kubernetes_cluster.main"].default_node_pool[0].orchestrator_version
      else
        $state["module.aks.azurerm_kubernetes_cluster_node_pool.node_pool_create_before_destroy[\"" + $name + "\"]"].orchestrator_version
      end;
    def update_address($name):
      if $name == "system" then "module.aks.azapi_update_resource.aks_cluster_default_nodepool_version[0]"
      else "module.aks.azapi_update_resource.node_pool_version[\"" + $name + "\"]" end;
    def keeper_address($name):
      if $name == "system" then "module.aks.null_resource.orchestrator_version_keeper[0]"
      else "module.aks.null_resource.node_pool_orchestrator_version_keeper[\"" + $name + "\"]" end;
    def changed($run): [$plans[$run][] | select(.change.actions != ["no-op"])];
    ([
      "module.aks.null_resource.kubernetes_version_keeper",
      "module.aks.time_sleep.interval_before_cluster_update[0]",
      "module.aks.azapi_update_resource.aks_cluster_post_create"
    ] + [pools[] | keeper_address(.), update_address(.)] | sort) as $expected_replacements |
    require($passed; "A test run failed") |
    require(all(pools[];
      pool_version(.) == "1.34" and $state[update_address(.)].body.properties.orchestratorVersion == "1.34");
      "Every pool must be created at cluster_version") |
    require(changed("plan_same_version") == []; "The same cluster_version must plan no changes") |
    require([changed("plan_next_minor")[] | select(.mode == "managed")] |
      all(.change.actions == ["create", "delete"]) and (map(.address) | sort) == $expected_replacements;
      "The next minor must replace exactly the upstream version keepers, time_sleep and version updates") |
    require([changed("plan_next_minor")[] | select(.mode == "data")] | all(.change.actions == ["read"]);
      "Data sources may only be re-read") |
    require([changed("plan_next_minor")[] | select(.address | test("azapi_update_resource\\.(aks_cluster_default_nodepool_version|node_pool_version)"))] |
      all(.change.after.body.properties.orchestratorVersion == "1.35");
      "Every pool version update must target the next minor") |
    "Cluster version upgrade assertions passed"
  '

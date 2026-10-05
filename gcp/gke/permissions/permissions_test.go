package permissions

import (
	"slices"
	"testing"
)

func TestProvisionerRoleParses(t *testing.T) {
	role, err := ProvisionerRole()
	if err != nil {
		t.Fatalf("ProvisionerRole: %v", err)
	}
	if role.Title == "" || role.Stage == "" {
		t.Fatalf("title/stage missing: %+v", role)
	}
	// The credential check the orchestrator runs before provisioning.
	if !slices.Contains(role.IncludedPermissions, "compute.zones.list") {
		t.Fatal("role must include compute.zones.list")
	}
	seen := map[string]bool{}
	for _, p := range role.IncludedPermissions {
		if seen[p] {
			t.Errorf("duplicate permission %q", p)
		}
		seen[p] = true
	}
}

func TestNativeEgressLifecyclePermissions(t *testing.T) {
	role, err := ProvisionerRole()
	if err != nil {
		t.Fatal(err)
	}
	for _, api := range []string{"networksecurity.googleapis.com", "privateca.googleapis.com"} {
		if !slices.Contains(RequiredAPIs, api) {
			t.Errorf("missing native firewall API %s", api)
		}
	}
	for _, resource := range []string{"firewallEndpoints", "firewallEndpointAssociations", "securityProfiles", "securityProfileGroups"} {
		for _, verb := range []string{"create", "get", "list", "update", "delete"} {
			permission := "networksecurity." + resource + "." + verb
			if !slices.Contains(role.IncludedPermissions, permission) {
				t.Errorf("missing lifecycle permission %s", permission)
			}
		}
	}
	for _, verb := range []string{"create", "get", "list", "update", "delete", "use"} {
		permission := "compute.firewallPolicies." + verb
		if !slices.Contains(role.IncludedPermissions, permission) {
			t.Errorf("missing policy permission %s", permission)
		}
	}
	for _, verb := range []string{"addAssociation", "removeAssociation", "addRule", "updateRule", "removeRule"} {
		if slices.Contains(role.IncludedPermissions, "compute.firewallPolicies."+verb) {
			t.Errorf("API method %s is not an IAM permission; policy updates authorize it", verb)
		}
	}
	for _, permission := range []string{"networksecurity.operations.get", "networksecurity.operations.list", "compute.networks.getEffectiveFirewalls", "compute.networks.setFirewallPolicy"} {
		if !slices.Contains(role.IncludedPermissions, permission) {
			t.Errorf("missing diagnostics permission %s", permission)
		}
	}
}

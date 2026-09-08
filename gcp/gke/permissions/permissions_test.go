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

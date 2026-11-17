package permissions

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
)

func TestPermissionsVersion(t *testing.T) {
	role, err := ProvisionerRole()
	if err != nil {
		t.Fatal(err)
	}
	content, err := json.Marshal(struct {
		Custom     []string `json:"custom"`
		Predefined []string `json:"predefined"`
	}{role.IncludedPermissions, PredefinedRoles})
	if err != nil {
		t.Fatal(err)
	}
	// Keep previous versions pinned; append a version/hash when the grants change.
	hashes := map[string]string{
		"1": "eee778e4b997fe10fe2c0f777ddbd2398c347b60b77877dcfdd2c05e4ecb75e5",
	}
	want, ok := hashes[PermissionsVersion]
	if !ok {
		t.Fatalf("pin the permission SHA-256 for PermissionsVersion %q", PermissionsVersion)
	}
	if got := fmt.Sprintf("%x", sha256.Sum256(content)); got != want {
		t.Fatalf("permission SHA-256 = %s, want %s for version %s; bump PermissionsVersion and add its hash when grants change", got, want, PermissionsVersion)
	}
}

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

func TestManagedStateBackendPermissions(t *testing.T) {
	role, err := ProvisionerRole()
	if err != nil {
		t.Fatal(err)
	}
	var storagePermissions []string
	for _, permission := range role.IncludedPermissions {
		if strings.HasPrefix(permission, "storage.") {
			storagePermissions = append(storagePermissions, permission)
		}
	}
	slices.Sort(storagePermissions)
	want := []string{
		"storage.buckets.create",
		"storage.buckets.get",
		"storage.buckets.getIamPolicy",
		"storage.buckets.setIamPolicy",
		"storage.buckets.update",
	}
	if !slices.Equal(storagePermissions, want) {
		t.Errorf("managed state needs bucket control-plane permissions only: got %v, want %v", storagePermissions, want)
	}
	if !slices.Contains(RequiredAPIs, "storage.googleapis.com") {
		t.Error("setup must enable the Cloud Storage API")
	}
}

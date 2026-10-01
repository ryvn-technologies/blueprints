package permissions

import (
	"slices"
	"strings"
	"testing"
)

func TestProvisionerRoleParses(t *testing.T) {
	role, err := ProvisionerRole()
	if err != nil {
		t.Fatalf("ProvisionerRole: %v", err)
	}
	if role.RoleName != RoleName {
		t.Fatalf("name %q, want %q", role.RoleName, RoleName)
	}
	if role.AssignableScopes[0] != "/subscriptions/"+SubscriptionPlaceholder {
		t.Fatalf("assignableScopes template missing: %v", role.AssignableScopes)
	}
	actions := role.Permissions[0].Actions
	// azurerm_kubernetes_cluster reads user credentials on every refresh.
	if !slices.Contains(actions, "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action") {
		t.Fatal("role must include listClusterUserCredential/action")
	}
	// azurerm_kubernetes_cluster manages planned maintenance windows as child maintenanceConfigurations.
	for _, verb := range []string{"read", "write", "delete"} {
		action := "Microsoft.ContainerService/managedClusters/maintenanceConfigurations/" + verb
		if !slices.Contains(actions, action) {
			t.Errorf("role must include %s", action)
		}
	}
	seen := map[string]bool{}
	for _, action := range actions {
		if seen[action] {
			t.Errorf("duplicate action %q", action)
		}
		seen[action] = true
		if action == "*" || strings.HasSuffix(action, "/*") {
			t.Errorf("role grants wildcard action %q", action)
		}
	}
	if len(role.Permissions[0].DataActions) != 0 {
		t.Error("role must not grant dataActions")
	}
}

// The managed egress firewall (egress_firewall.enabled) needs full lifecycle
// permissions on the firewall, its policy, SNAT public IP, route table and
// verdict-log destinations. Each resource type must carry read/write/delete
// explicitly rather than via wildcards.
func TestProvisionerRoleCoversEgressFirewallLifecycle(t *testing.T) {
	role, err := ProvisionerRole()
	if err != nil {
		t.Fatalf("ProvisionerRole: %v", err)
	}
	actions := role.Permissions[0].Actions
	lifecycle := []string{
		"Microsoft.Network/azureFirewalls",
		"Microsoft.Network/firewallPolicies",
		"Microsoft.Network/firewallPolicies/ruleCollectionGroups",
		"Microsoft.Network/publicIPAddresses",
		"Microsoft.Network/routeTables",
		"Microsoft.Network/routeTables/routes",
		"Microsoft.Insights/diagnosticSettings",
		"Microsoft.OperationalInsights/workspaces",
	}
	for _, resource := range lifecycle {
		for _, verb := range []string{"read", "write", "delete"} {
			if action := resource + "/" + verb; !slices.Contains(actions, action) {
				t.Errorf("role must include %q", action)
			}
		}
	}
	for _, action := range []string{
		"Microsoft.Network/virtualNetworks/subnets/join/action",
		"Microsoft.Network/routeTables/join/action",
		"Microsoft.Network/publicIPAddresses/join/action",
		"Microsoft.Network/firewallPolicies/join/action",
		"Microsoft.OperationalInsights/workspaces/sharedKeys/action",
		"Microsoft.Resources/subscriptions/providers/read",
	} {
		if !slices.Contains(actions, action) {
			t.Errorf("role must include %q", action)
		}
	}
}

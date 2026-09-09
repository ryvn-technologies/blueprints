// Package permissions is the source of truth for what an Azure subscription
// must grant Ryvn to provision AKS environments with the
// infra/azure-aks-provision module. The orchestrator serves it over the API so
// setup instructions track the module rather than a copy of it.
package permissions

import (
	_ "embed"
	"encoding/json"
	"fmt"
)

//go:embed provisioner-role.json
var provisionerRoleJSON []byte

// RoleName is the custom role's display name (`roleName`) in the customer
// subscription. It is the value `az role assignment create --role` and
// `az ad sp create-for-rbac --role` resolve, and it matches the name the
// previous wildcard definition used so `az role definition update` replaces
// that definition in place.
const RoleName = "ryvn-aks-provision"

// SubscriptionPlaceholder is the token in assignableScopes that the
// orchestrator swaps for the customer's subscription ID.
const SubscriptionPlaceholder = "<subscriptionId>"

// Role mirrors the file format accepted by `az role definition create --role-definition`.
type Role struct {
	RoleName         string       `json:"roleName"`
	Description      string       `json:"description"`
	AssignableScopes []string     `json:"assignableScopes"`
	Permissions      []Permission `json:"permissions"`
}

// Permission is one entry of Role.Permissions.
type Permission struct {
	Actions        []string `json:"actions"`
	NotActions     []string `json:"notActions"`
	DataActions    []string `json:"dataActions"`
	NotDataActions []string `json:"notDataActions"`
}

// ProvisionerRole parses the embedded role definition.
func ProvisionerRole() (Role, error) {
	var role Role
	if err := json.Unmarshal(provisionerRoleJSON, &role); err != nil {
		return Role{}, fmt.Errorf("parse provisioner-role.json: %w", err)
	}
	if len(role.Permissions) != 1 || len(role.Permissions[0].Actions) == 0 {
		return Role{}, fmt.Errorf("provisioner-role.json must have exactly one permissions entry with actions")
	}
	return role, nil
}

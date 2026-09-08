// Package permissions is the source of truth for what a Google Cloud project
// must grant Ryvn to provision GKE environments with the infra/gke-provision
// module. The orchestrator serves it over the API so setup instructions track
// the module rather than a copy of it.
package permissions

import (
	_ "embed"
	"fmt"

	"github.com/goccy/go-yaml"
)

//go:embed provisioner-role.yaml
var provisionerRoleYAML []byte

// RoleID is the custom role's ID in the customer project (projects/<p>/roles/<RoleID>).
const RoleID = "ryvnProvisioner"

// ServiceAccountID is the account ID of the service account Ryvn impersonates.
const ServiceAccountID = "ryvn-provisioner"

// PredefinedRoles are bound alongside the custom role. roles/container.admin
// carries the Kubernetes-side permissions used to install the in-cluster agent.
var PredefinedRoles = []string{"roles/container.admin"}

// RequiredAPIs must be enabled in the target project before provisioning.
var RequiredAPIs = []string{
	"iam.googleapis.com",
	"iamcredentials.googleapis.com",
	"sts.googleapis.com",
	"cloudresourcemanager.googleapis.com",
	"compute.googleapis.com",
	"container.googleapis.com",
	"servicenetworking.googleapis.com",
	"dns.googleapis.com",
	"cloudkms.googleapis.com",
}

// Role mirrors the file format accepted by `gcloud iam roles create --file`.
type Role struct {
	Title               string   `yaml:"title"`
	Description         string   `yaml:"description"`
	Stage               string   `yaml:"stage"`
	IncludedPermissions []string `yaml:"includedPermissions"`
}

// ProvisionerRole parses the embedded role definition.
func ProvisionerRole() (Role, error) {
	var role Role
	if err := yaml.Unmarshal(provisionerRoleYAML, &role); err != nil {
		return Role{}, fmt.Errorf("parse provisioner-role.yaml: %w", err)
	}
	if len(role.IncludedPermissions) == 0 {
		return Role{}, fmt.Errorf("provisioner-role.yaml has no includedPermissions")
	}
	return role, nil
}

# Core Configuration
variable "environment" {
  description = "Environment name"
  type        = string
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "zones" {
  description = "List of zones for the GKE cluster"
  type        = list(string)
  default     = []
}

# Kubernetes Secrets encryption
variable "create_cluster_kms_key" {
  description = "Create a Cloud KMS key and encrypt Kubernetes Secrets with it. Set to false if your project does not allow creating keys. Secrets then use Google's default encryption only. Ignored when existing_cluster_kms_key_name is set."
  type        = bool
  default     = true
}

variable "existing_cluster_kms_key_name" {
  description = "Your own Cloud KMS key for Kubernetes Secrets, as projects/PROJECT/locations/REGION/keyRings/RING/cryptoKeys/KEY. It must be in the cluster's region, and the GKE service agent must already have the Cloud KMS CryptoKey Encrypter/Decrypter role on it."
  type        = string
  default     = null

  validation {
    condition = var.existing_cluster_kms_key_name == null || can(regex(
      "^projects/[^/]+/locations/${var.region}/keyRings/[^/]+/cryptoKeys/[^/]+$",
      var.existing_cluster_kms_key_name,
    ))
    error_message = "existing_cluster_kms_key_name must be in the cluster's region, in the form projects/PROJECT/locations/REGION/keyRings/RING/cryptoKeys/KEY."
  }
}

# Network Configuration
variable "subnet_cidr" {
  description = "CIDR range for the subnet"
  type        = string
  default     = "10.0.0.0/17"
}

variable "cluster_service_account_name" {
  description = "The name of the service account to run nodes as"
  type        = string
  default     = ""
}

variable "pod_cidr" {
  description = "CIDR range for pods"
  type        = string
  default     = "192.168.0.0/18"
}

variable "service_cidr" {
  description = "CIDR range for services"
  type        = string
  default     = "192.168.64.0/18"
}

# GKE pins the datapath at cluster creation and the provider marks the field
# ForceNew, so changing this on an already-provisioned environment plans a
# cluster replacement rather than an in-place migration. Surfaced to users as
# the `dataplaneV2` input on the gcp-platform blueprint.
variable "datapath_provider" {
  description = "The desired datapath provider for this cluster. `DATAPATH_PROVIDER_UNSPECIFIED` uses the IPTables-based kube-proxy implementation; `ADVANCED_DATAPATH` enables Dataplane V2, the Cilium eBPF-powered datapath. Only applied at cluster creation."
  type        = string
  default     = "DATAPATH_PROVIDER_UNSPECIFIED"
  validation {
    condition     = contains(["DATAPATH_PROVIDER_UNSPECIFIED", "LEGACY_DATAPATH", "ADVANCED_DATAPATH"], var.datapath_provider)
    error_message = "datapath_provider \"${var.datapath_provider}\" is not a valid GKE datapath. Use DATAPATH_PROVIDER_UNSPECIFIED, LEGACY_DATAPATH, or ADVANCED_DATAPATH."
  }
}

# Node Pools Configuration
variable "node_pools" {
  description = "Map of node pool definitions to create"
  type = map(object({
    machine_type       = optional(string)
    total_min_count    = optional(number)
    total_max_count    = optional(number)
    initial_node_count = optional(number)
    disk_size_gb       = optional(number)
    disk_type          = optional(string)
    labels             = optional(map(string))
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string # NO_SCHEDULE, PREFER_NO_SCHEDULE, NO_EXECUTE
    })))
  }))
  default = {}
}

variable "node_pools_labels" {
  description = "Map of node pool labels to apply to each node pool"
  type        = map(map(string))
  default     = {}
}

# Flow Logs Configuration
variable "flow_logs" {
  description = "Configuration for VPC flow logs"
  type = object({
    enable          = string
    interval        = optional(string, "INTERVAL_5_SEC")
    sampling        = optional(string, "0.5")
    metadata        = optional(string, "INCLUDE_ALL_METADATA")
    filter          = optional(string, "true")
    metadata_fields = optional(list(string), [])
  })
  default = {
    enable = "true"
  }
}

# Namespace Configuration
variable "ryvn_system_namespace" {
  description = "Kubernetes namespace where ryvn system components are deployed"
  type        = string
  default     = "ryvn-system"
}

variable "external_dns_namespace" {
  description = "Kubernetes namespace where external-dns is deployed"
  type        = string
  default     = "external-dns"
}

variable "cert_manager_namespace" {
  description = "Kubernetes namespace where cert-manager is deployed"
  type        = string
  default     = "cert-manager"
}

# DNS Configuration
variable "public_root_domain" {
  description = "The root domain for public DNS zone"
  type        = string
}

variable "internal_root_domain" {
  description = "The root domain for internal private DNS zone"
  type        = string
}

variable "skip_dns_provisioning" {
  description = "Skip provisioning DNS managed zones"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Blocks Terraform from destroying the cluster and DNS zones until it is explicitly disabled and applied before deprovisioning."
  type        = bool
  default     = false
}

# IAM Configuration
variable "cluster_bootstrap_perms" {
  description = "Whether to grant the Terraform service account cluster admin permissions"
  type        = bool
  default     = false
}

variable "terraform_executor_policies" {
  description = "Additional IAM policies to be added to the Ryvn Agent role. Can specify either predefined roles or custom permissions. If custom permissions are specified, they will override the default permissions."
  type = object({
    # Optional list of predefined GCP roles to attach
    roles = optional(list(string), [])
    # Optional list of custom permissions to add. If specified, these will override the default permissions.
    permissions = optional(list(string), [])
  })
  default = {
    roles       = []
    permissions = []
  }
  validation {
    condition     = length(var.terraform_executor_policies.roles) == 0 || length(var.terraform_executor_policies.permissions) == 0
    error_message = "Cannot specify both roles and permissions in terraform_executor_policies."
  }
}

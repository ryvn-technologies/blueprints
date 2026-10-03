# Core Configuration
variable "environment" {
  description = "Environment name"
  type        = string
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "provisioner_service_account_email" {
  description = "Service account to impersonate for provisioning. When unset, use the provider's default credentials."
  type        = string
  default     = null
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
  description = "IAM grants for the Ryvn agent (the identity that runs installation Terraform). Empty keeps the default custom role and the tag-scoped Cloud SQL grant. Anything supplied replaces that default set outright: `roles` binds predefined roles, `permissions` builds one custom role, and `bindings` binds a role or custom permissions under an optional IAM condition."
  type = object({
    # Optional list of predefined GCP roles to attach
    roles = optional(list(string), [])
    # Optional permissions for the agent's custom role in place of the defaults.
    permissions = optional(list(string), [])
    # Optional role bindings for the agent, each with an optional IAM condition.
    bindings = optional(list(object({
      # Stable key for the binding; also suffixes the custom role id (ryvn_agent_<env>_<name>) when permissions are given.
      name = string
      # Predefined or existing custom role to bind, e.g. roles/cloudkms.admin.
      role = optional(string)
      # Permissions for a custom role created for this binding. Exactly one of role or permissions.
      permissions = optional(list(string), [])
      # IAM condition on the binding, in the same shape as gcloud --condition.
      condition = optional(object({
        title       = string
        description = optional(string)
        expression  = string
      }))
    })), [])
  })
  default = {
    roles       = []
    permissions = []
    bindings    = []
  }
  validation {
    condition = alltrue([
      for b in var.terraform_executor_policies.bindings : (b.role != null) != (length(b.permissions) > 0)
    ])
    error_message = "Each terraform_executor_policies.bindings entry must set exactly one of role or permissions."
  }
  validation {
    condition = alltrue([
      for b in var.terraform_executor_policies.bindings : can(regex("^[a-z0-9]([a-z0-9-]{0,10}[a-z0-9])?$", b.name))
    ])
    error_message = "terraform_executor_policies.bindings[*].name must be 1-12 lowercase alphanumeric characters or hyphens, not starting or ending with a hyphen."
  }
  validation {
    condition     = length(distinct([for b in var.terraform_executor_policies.bindings : b.name])) == length(var.terraform_executor_policies.bindings)
    error_message = "terraform_executor_policies.bindings[*].name must be unique."
  }
}

# ============================================================================
# Managed default-deny egress
# ============================================================================

variable "egress_firewall" {
  nullable    = false
  description = "Native Cloud NGFW default-deny egress. Omitted/disabled preserves legacy networking. Domain patterns match Host or visible SNI per source class and TCP80/443; TCP443 does not enforce TLS-only application semantics. Exact public TCP/UDP tuples bypass domain matching. Web and tuples use stable root Cloud NAT IPs. additional_workload_zones adds endpoint coverage for external workloads beyond GKE zones; no SWP is installed."
  type = object({
    enabled                   = optional(bool, false)
    default_action            = optional(string, "deny")
    cluster_policy_key        = optional(string, "cluster")
    additional_workload_zones = optional(set(string), [])
    policies = optional(map(object({
      domain_allow = optional(map(object({
        domains           = set(string)
        protocol          = string
        destination_ports = optional(set(number))
      })), {})
      network_allow = optional(map(object({
        destination_ipv4_cidrs = set(string)
        protocol               = string
        destination_ports      = set(number)
        reason                 = string
      })), {})
    })), {})
  })
  default = {}

  validation {
    condition     = !var.egress_firewall.enabled || var.egress_firewall.default_action == "deny"
    error_message = "egress_firewall.default_action must be \"deny\"; v1 has no permit-rest mode."
  }

  validation {
    condition     = !var.egress_firewall.enabled || contains(keys(var.egress_firewall.policies), var.egress_firewall.cluster_policy_key)
    error_message = "egress_firewall.cluster_policy_key must name an existing entry in egress_firewall.policies."
  }

  validation {
    condition     = alltrue([for zone in var.egress_firewall.additional_workload_zones : startswith(zone, "${var.region}-")])
    error_message = "additional_workload_zones must belong to the environment region."
  }

  validation {
    condition = alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for rule in values(policy.domain_allow) : (
          contains(["http", "https"], rule.protocol) &&
          length(rule.domains) > 0 &&
          (rule.destination_ports == null || (length(rule.destination_ports) == 1 && contains(rule.destination_ports, rule.protocol == "http" ? 80 : 443)))
        )
      ]
    ]))
    error_message = "egress_firewall domain_allow entries need nonempty domains, protocol http or https, and if destination_ports is set, exactly [80] for http or [443] for https."
  }

  validation {
    condition = alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for domain in flatten([for rule in values(policy.domain_allow) : tolist(rule.domains)]) : (
          length(domain) <= 253 &&
          domain == lower(domain) &&
          can(regex("^(\\*\\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", domain)) &&
          !can(regex("^(\\*\\.)?[0-9]+(\\.[0-9]+){3}$", domain))
        )
      ]
    ]))
    error_message = "egress_firewall domain patterns must be lowercase canonical DNS names, exact (example.com) or leading-wildcard (*.example.com): no bare *, leading dot, partial/internal wildcards, IP literals, URLs, paths, ports, trailing dots or invalid labels."
  }

  validation {
    condition = alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for domain in flatten([for rule in values(policy.domain_allow) : tolist(rule.domains)]) : !startswith(domain, "*.") || (
          (!can(local.egress_public_suffixes[domain]) || can(local.egress_public_suffixes["!${trimprefix(domain, "*.")}"])) &&
          !can(local.egress_public_suffixes[trimprefix(domain, "*.")]) &&
          !(length(split(".", trimprefix(domain, "*."))) > 1 &&
            can(local.egress_public_suffixes["*.${join(".", slice(split(".", trimprefix(domain, "*.")), 1, length(split(".", trimprefix(domain, "*.")))))}"]) &&
          !can(local.egress_public_suffixes["!${trimprefix(domain, "*.")}"]))
        )
      ]
    ]))
    error_message = "egress_firewall wildcard domains must have a registrable apex, not a public suffix (e.g. *.com, *.co.uk, *.googleapis.com, *.run.app)."
  }

  validation {
    condition = alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for rule in values(policy.network_allow) : (
          contains(["tcp", "udp"], rule.protocol) &&
          length(rule.destination_ports) > 0 &&
          alltrue([for port in rule.destination_ports : port == floor(port) && port >= 1 && port <= 65535]) &&
          length(trimspace(rule.reason)) > 0 &&
          length(rule.destination_ipv4_cidrs) > 0
        )
      ]
    ]))
    error_message = "egress_firewall network_allow entries require protocol tcp|udp, nonempty explicit integer destination_ports 1-65535, nonempty destination_ipv4_cidrs and a nonempty reason."
  }

  validation {
    condition = alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for rule in values(policy.network_allow) : !(rule.protocol == "udp" && contains(rule.destination_ports, 443))
      ]
    ]))
    error_message = "egress_firewall network_allow must not open UDP/443; the QUIC block is part of the v1 contract."
  }

  validation {
    condition = !var.egress_firewall.enabled || alltrue(flatten([
      for policy in values(var.egress_firewall.policies) : [
        for rule in values(policy.network_allow) : [
          for cidr in rule.destination_ipv4_cidrs : (
            can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+$", cidr)) &&
            can(cidrnetmask(cidr)) &&
            try(cidrsubnet(cidr, 0, 0) == cidr, false) &&
            try(tonumber(split("/", cidr)[1]) >= 8, false) &&
            try(alltrue([
              for reserved in local.egress_rejected_destination_cidrs :
              cidrsubnet("${cidrhost(cidr, 0)}/${min(tonumber(split("/", cidr)[1]), tonumber(split("/", reserved)[1]))}", 0, 0) !=
              cidrsubnet("${cidrhost(reserved, 0)}/${min(tonumber(split("/", cidr)[1]), tonumber(split("/", reserved)[1]))}", 0, 0)
            ]), false)
          )
        ]
      ]
    ]))
    error_message = "egress_firewall network_allow destination_ipv4_cidrs must be normalized public IPv4 CIDRs (/8 or smaller): no IPv6, 0.0.0.0/0, multicast, reserved, link-local, RFC 1918 or the environment's subnet, pod and service ranges."
  }
}

variable "platform_https_domains" {
  nullable    = false
  description = "Additional exact HTTPS/443 hostnames for cluster platform sources only (the managing Ryvn hub API and issuer, the collector's Loki/Mimir gateways and token endpoint, an access tunnel); added to the built-in GKE and registry baseline, never replacing it. The Ryvn GCP platform blueprint derives these from the managing hub; standalone callers list them. Ignored while egress_firewall.enabled = false."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([for domain in var.platform_https_domains : (
      length(domain) <= 253 &&
      domain == lower(domain) &&
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", domain))
    )])
    error_message = "platform_https_domains requires exact lowercase multi-label DNS hostnames without wildcards, URL schemes, ports, paths or trailing dots."
  }
}

variable "additional_subnet_groups" {
  nullable    = false
  description = "Ordered, append-only allocation of regional subnets for compute that runs outside the cluster, carved in declaration order from additional_subnet_groups_cidr. Independent of egress_firewall: a group has VPC-local connectivity only (no Cloud NAT) until an egress_attachments entry assigns it a policy; Private Google Access stays off. Never edit, reorder, resize, rename or remove an applied entry (the plan is rejected); append a group for more capacity and set retired = true to remove its subnet while keeping its range reserved."
  type = list(object({
    name               = string
    ipv4_prefix_length = number
    retired            = optional(bool, false)
  }))
  default = []

  validation {
    condition = length(distinct([for group in var.additional_subnet_groups : group.name])) == length(var.additional_subnet_groups) && alltrue([
      for group in var.additional_subnet_groups : group.name != "cluster" && can(regex("^[a-z][a-z0-9_]{0,30}$", group.name))
    ])
    error_message = "additional_subnet_groups names must be unique, match ^[a-z][a-z0-9_]{0,30}$ and not be cluster."
  }
}

variable "additional_subnet_groups_cidr" {
  description = "Private range additional_subnet_groups are allocated from. Must not overlap subnet_cidr, pod_cidr, service_cidr or the private services range. Fixed once a group is applied."
  type        = string
  default     = "10.0.192.0/19"

  validation {
    condition = (
      can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+$", var.additional_subnet_groups_cidr)) &&
      try(cidrsubnet(var.additional_subnet_groups_cidr, 0, 0) == var.additional_subnet_groups_cidr, false) &&
      anytrue([for private in local.egress_private_ranges :
        try(cidrsubnet("${cidrhost(var.additional_subnet_groups_cidr, 0)}/${split("/", private)[1]}", 0, 0) == private && tonumber(split("/", var.additional_subnet_groups_cidr)[1]) >= tonumber(split("/", private)[1]), false)
      ])
    )
    error_message = "additional_subnet_groups_cidr must be a normalized private IPv4 CIDR inside RFC 1918 or 100.64.0.0/10."
  }
}

variable "egress_attachments" {
  nullable    = false
  description = "Named external compute classes: each assigns one active additional_subnet_groups entry (subnet_group_key) to one egress_firewall policy (policy_key). No CIDRs and no subnet creation here; requires egress_firewall.enabled = true."
  type = map(object({
    subnet_group_key = string
    policy_key       = string
  }))
  default = {}

  validation {
    condition     = length(var.egress_attachments) == 0 || var.egress_firewall.enabled
    error_message = "egress_attachments requires egress_firewall.enabled = true; with the firewall disabled nothing would protect those subnets."
  }

  validation {
    condition     = !contains(keys(var.egress_attachments), "cluster") && alltrue([for key in keys(var.egress_attachments) : can(regex("^[a-z][a-z0-9_]{0,30}$", key))])
    error_message = "egress_attachments keys must match ^[a-z][a-z0-9_]{0,30}$ and not be the reserved name \"cluster\"."
  }

  validation {
    condition     = alltrue([for attachment in values(var.egress_attachments) : contains(keys(var.egress_firewall.policies), attachment.policy_key)])
    error_message = "egress_attachments[*].policy_key must name an existing egress_firewall.policies entry."
  }

  validation {
    condition = alltrue([for attachment in values(var.egress_attachments) :
      contains([for group in var.additional_subnet_groups : group.name if !group.retired], attachment.subnet_group_key)
    ])
    error_message = "egress_attachments[*].subnet_group_key must name an active additional_subnet_groups entry; remove the attachment before retiring a group."
  }

  validation {
    condition     = length(distinct([for attachment in values(var.egress_attachments) : attachment.subnet_group_key])) == length(var.egress_attachments)
    error_message = "Each additional_subnet_groups entry can be assigned to at most one egress_attachments entry, even with the same policy_key."
  }
}

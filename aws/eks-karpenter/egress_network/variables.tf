variable "name" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "vpc_cidrs" {
  description = "Every IPv4 CIDR associated with the VPC (primary plus secondaries such as a Cilium pod CIDR). Protected source subnets may live in any of them, and each gets a NAT-table local-route audit entry."
  type        = list(string)
  default     = []
}
variable "igw_id" { type = string }
variable "azs" { type = list(string) }
variable "tags" {
  type    = map(string)
  default = {}
}
variable "cluster_subnets_by_az" {
  type = map(object({ subnet_id = string, ipv4_cidr = string, route_table_id = string }))
}
variable "cluster_default_route_ids" {
  description = "Set when the caller owns the 0.0.0.0/0 -> firewall endpoint route of each cluster route table (route IDs per AZ, built from firewall_endpoint_ids). The module then creates none and publishes cluster_subnet_ids only after those routes exist. The production root does this so one route resource serves both firewall modes and a mode switch replaces the target in place; standalone fixtures leave it null."
  type        = map(string)
  default     = null
}
variable "cluster_source_cidrs_by_az" {
  type    = map(list(string))
  default = {}
}
variable "reserved_subnet_cidrs" {
  type    = list(string)
  default = []
}
variable "firewall_subnet_cidrs" { type = map(string) }
variable "nat_subnet_cidrs" { type = map(string) }
variable "attachments" {
  type    = map(object({ policy_key = string, subnets_by_az = map(object({ ipv4_cidr = string })) }))
  default = {}
}
variable "cluster_policy_key" { type = string }
variable "platform_https_domains" {
  type    = set(string)
  default = []
}
variable "policies" {
  type = map(object({
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
  }))

  validation {
    condition = alltrue(flatten([for p in values(var.policies) : [for rule in values(p.domain_allow) :
      length(rule.domains) > 0 && contains(["http", "https"], rule.protocol) &&
      (rule.destination_ports == null || rule.destination_ports == toset([rule.protocol == "http" ? 80 : 443]))
    ]]))
    error_message = "Each domain_allow rule needs a non-empty domains set and protocol http or https; destination_ports may be omitted (80/443 by protocol) but v1 accepts only http+80 and https+443."
  }

  validation {
    condition = alltrue(flatten([for p in values(var.policies) : [for rule in values(p.domain_allow) : [for d in rule.domains :
      d == lower(d) && length(d) <= 255 && can(regex("^(\\*\\.)?[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$", d)) &&
      alltrue([for label in split(".", trimprefix(d, "*.")) : length(label) <= 63]) &&
      !can(cidrhost("${trimprefix(d, "*.")}/32", 0))
    ]]]))
    error_message = "Domain allows must be lowercase DNS names or leftmost *. subdomains, without URLs, IPs, ports or trailing dots."
  }

  validation {
    condition = alltrue(flatten([for p in values(var.policies) : [for rule in values(p.network_allow) :
      contains(["tcp", "udp"], rule.protocol) && length(trimspace(rule.reason)) > 0 &&
      length(rule.destination_ports) > 0 && alltrue([for port in rule.destination_ports : port >= 1 && port <= 65535 && floor(port) == port && !(rule.protocol == "udp" && port == 443)]) &&
      length(rule.destination_ipv4_cidrs) > 0 && alltrue([for c in rule.destination_ipv4_cidrs :
        can(cidrhost(c, 0)) && can(regex("^[0-9.]+/[0-9]+$", c)) && c != "0.0.0.0/0" &&
        try(cidrsubnet(c, 0, 0), "") == c
      ])
    ]]))
    error_message = "Network exceptions require normalized public IPv4 CIDRs, tcp/udp and narrow integer ports; UDP443 is unsupported."
  }
}

variable "change_protection" {
  description = "Set the firewall's delete, subnet-change and policy-change protection. AWS refuses DeleteFirewall, subnet-mapping and policy-association changes while set, and the provider does not lift it for you: apply with false before destroying the firewall or changing its AZ set, then restore true."
  type        = bool
  default     = true
}

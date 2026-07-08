variable "aws_region" {
  description = "AWS region for non-CloudFront global APIs. CloudFront, CloudFront-scoped WAF, and ACM viewer certificates are managed through the us-east-1 provider alias."
  type        = string
  default     = "us-east-1"
  nullable    = false

  validation {
    condition     = var.aws_region != "" && trimspace(var.aws_region) == var.aws_region
    error_message = "aws_region must be a non-empty AWS region with no leading or trailing whitespace."
  }
}

variable "name_prefix" {
  description = "Prefix for named AWS resources created by this module."
  type        = string
  default     = "ryvn-cloudfront-edge"
  nullable    = false

  validation {
    condition     = var.name_prefix != "" && trimspace(var.name_prefix) == var.name_prefix
    error_message = "name_prefix must be non-empty and must not have leading or trailing whitespace."
  }

  validation {
    condition     = trim(replace(lower(var.name_prefix), "/[^a-z0-9-]+/", "-"), "-") != ""
    error_message = "name_prefix must contain at least one ASCII letter or digit after normalization."
  }
}

variable "managed_public_dns_root" {
  description = "Managed public DNS root for this environment. Ryvn blueprints should inject this from .ryvn.env.state.public_domain.name."
  type        = string
  nullable    = false

  validation {
    condition = (
      var.managed_public_dns_root != "" &&
      trimspace(var.managed_public_dns_root) == var.managed_public_dns_root &&
      length(regexall("\\s", var.managed_public_dns_root)) == 0 &&
      !strcontains(var.managed_public_dns_root, "://") &&
      !strcontains(var.managed_public_dns_root, "/") &&
      !strcontains(var.managed_public_dns_root, ":") &&
      !strcontains(var.managed_public_dns_root, "*") &&
      !startswith(var.managed_public_dns_root, ".") &&
      !endswith(var.managed_public_dns_root, ".") &&
      !strcontains(var.managed_public_dns_root, "..")
    )
    error_message = "managed_public_dns_root must be a non-empty domain name with no whitespace, URL scheme, path, port, wildcard, trailing dot, or empty label."
  }
}

variable "managed_private_dns_root" {
  description = "Managed private DNS root for this environment. Required when origin_type is internal or vpc. Ryvn blueprints should inject this from .ryvn.env.state.internal_domain.name."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition = var.managed_private_dns_root == "" ? !(contains(["internal", "vpc"], var.origin_type) && var.vpc_origin.domain_name == "") : (
      trimspace(var.managed_private_dns_root) == var.managed_private_dns_root &&
      length(regexall("\\s", var.managed_private_dns_root)) == 0 &&
      !strcontains(var.managed_private_dns_root, "://") &&
      !strcontains(var.managed_private_dns_root, "/") &&
      !strcontains(var.managed_private_dns_root, ":") &&
      !strcontains(var.managed_private_dns_root, "*") &&
      !startswith(var.managed_private_dns_root, ".") &&
      !endswith(var.managed_private_dns_root, ".") &&
      !strcontains(var.managed_private_dns_root, "..")
    )
    error_message = "managed_private_dns_root must be a domain name with no whitespace, URL scheme, path, port, wildcard, trailing dot, or empty label. It is required when origin_type is internal or vpc and vpc_origin.domain_name is empty."
  }
}

variable "hostnames" {
  description = "Public hostnames served by CloudFront. Leave empty to serve the managed public DNS root and wildcard. Multiple module installations in one AWS account must not reuse the same exact CloudFront alias."
  type        = set(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for hostname in var.hostnames :
      hostname != "" &&
      trimspace(hostname) == hostname &&
      length(regexall("\\s", hostname)) == 0 &&
      !strcontains(hostname, "://") &&
      !strcontains(hostname, "/") &&
      !strcontains(hostname, ":") &&
      !strcontains(trimprefix(hostname, "*."), "*") &&
      !startswith(hostname, ".") &&
      !endswith(hostname, ".") &&
      !strcontains(hostname, "..")
    ])
    error_message = "hostnames entries must be hostnames with no whitespace, URL scheme, path, port, trailing dot, empty label, or wildcard outside a leading *."
  }

  validation {
    condition = alltrue([
      for hostname in var.hostnames :
      (trimspace(var.viewer_certificate_arn) != "" && !var.dns.enabled) ||
      hostname == var.managed_public_dns_root ||
      hostname == "*.${var.managed_public_dns_root}" ||
      (
        endswith(hostname, ".${var.managed_public_dns_root}") &&
        length(split(".", trimsuffix(hostname, ".${var.managed_public_dns_root}"))) == 1
      )
    ])
    error_message = "When viewer_certificate_arn is empty or dns.enabled = true, hostnames must be the public domain apex, the public domain wildcard, or one-label subdomains covered by the module-managed public zone and wildcard viewer certificate."
  }
}

variable "origin_type" {
  description = "Origin mode for CloudFront. public uses origin.<managed_public_dns_root> with origin mTLS. internal uses internal-origin.<managed_private_dns_root> through a CloudFront VPC origin. vpc is accepted as an alias for internal."
  type        = string
  default     = "public"
  nullable    = false

  validation {
    condition     = contains(["public", "internal", "vpc"], var.origin_type)
    error_message = "origin_type must be public, internal, or vpc."
  }
}

variable "origin_hostname" {
  description = "Override for the Ryvn public origin hostname when origin_type = public. Defaults to origin.<managed_public_dns_root>."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition = var.origin_hostname == "" || (
      trimspace(var.origin_hostname) == var.origin_hostname &&
      length(regexall("\\s", var.origin_hostname)) == 0 &&
      !strcontains(var.origin_hostname, "://") &&
      !strcontains(var.origin_hostname, "/") &&
      !strcontains(var.origin_hostname, ":") &&
      !strcontains(var.origin_hostname, "*") &&
      !startswith(var.origin_hostname, ".") &&
      !endswith(var.origin_hostname, ".") &&
      !strcontains(var.origin_hostname, "..")
    )
    error_message = "origin_hostname must be empty or a hostname with no whitespace, URL scheme, path, port, wildcard, leading/trailing dot, or empty label."
  }
}

variable "origin_port" {
  description = "HTTPS port CloudFront uses when connecting to the Ryvn origin."
  type        = number
  default     = 443
  nullable    = false

  validation {
    condition     = var.origin_port > 0 && var.origin_port <= 65535
    error_message = "origin_port must be a valid TCP port."
  }
}

variable "origin_client_certificate_arn" {
  description = "ACM certificate ARN in us-east-1 that CloudFront presents to the Ryvn origin for origin mTLS. Required for public origins and unsupported for internal/VPC origins."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition = var.origin_type == "public" ? (
      var.origin_client_certificate_arn != "" &&
      trimspace(var.origin_client_certificate_arn) == var.origin_client_certificate_arn &&
      startswith(var.origin_client_certificate_arn, "arn:aws")
      ) : (
      var.origin_client_certificate_arn == ""
    )
    error_message = "origin_client_certificate_arn must be a non-empty ACM certificate ARN for public origins and must be empty for VPC origins."
  }
}

variable "vpc_origin" {
  description = "CloudFront VPC origin configuration used when origin_type = internal or vpc. Use either create = true with endpoint_arn or endpoint_lookup_tags, or existing_vpc_origin_id."
  type = object({
    create                   = optional(bool, false)
    existing_vpc_origin_id   = optional(string, "")
    endpoint_arn             = optional(string, "")
    endpoint_lookup_tags     = optional(map(string), {})
    domain_name              = optional(string, "")
    name                     = optional(string, "")
    http_port                = optional(number, 80)
    https_port               = optional(number, 443)
    origin_protocol_policy   = optional(string, "https-only")
    origin_ssl_protocols     = optional(list(string), ["TLSv1.2"])
    origin_keepalive_timeout = optional(number, 5)
    origin_read_timeout      = optional(number, 30)
    timeouts = optional(object({
      create = optional(string)
      update = optional(string)
      delete = optional(string)
    }))
    tags = optional(map(string), {})
  })
  default  = {}
  nullable = false

  validation {
    condition = !contains(["internal", "vpc"], var.origin_type) || var.vpc_origin.domain_name == "" || (
      trimspace(var.vpc_origin.domain_name) == var.vpc_origin.domain_name &&
      length(regexall("\\s", var.vpc_origin.domain_name)) == 0 &&
      !strcontains(var.vpc_origin.domain_name, "://") &&
      !strcontains(var.vpc_origin.domain_name, "/") &&
      !strcontains(var.vpc_origin.domain_name, ":") &&
      !strcontains(var.vpc_origin.domain_name, "*") &&
      !startswith(var.vpc_origin.domain_name, ".") &&
      !endswith(var.vpc_origin.domain_name, ".") &&
      !strcontains(var.vpc_origin.domain_name, "..")
    )
    error_message = "vpc_origin.domain_name must be empty or a hostname with no whitespace, URL scheme, path, port, wildcard, leading/trailing dot, or empty label when origin_type is internal or vpc."
  }

  validation {
    condition = !contains(["internal", "vpc"], var.origin_type) || (
      (var.vpc_origin.create && var.vpc_origin.existing_vpc_origin_id == "") ||
      (!var.vpc_origin.create && var.vpc_origin.existing_vpc_origin_id != "")
    )
    error_message = "Internal origins require exactly one of vpc_origin.create = true or vpc_origin.existing_vpc_origin_id."
  }

  validation {
    condition = !contains(["internal", "vpc"], var.origin_type) || !var.vpc_origin.create || (
      var.vpc_origin.endpoint_arn != "" ||
      length(var.vpc_origin.endpoint_lookup_tags) > 0
    )
    error_message = "vpc_origin.endpoint_arn or vpc_origin.endpoint_lookup_tags is required when origin_type is internal or vpc and vpc_origin.create = true."
  }

  validation {
    condition = (
      trimspace(var.vpc_origin.existing_vpc_origin_id) == var.vpc_origin.existing_vpc_origin_id &&
      trimspace(var.vpc_origin.endpoint_arn) == var.vpc_origin.endpoint_arn &&
      trimspace(var.vpc_origin.name) == var.vpc_origin.name
    )
    error_message = "vpc_origin string fields must not have leading or trailing whitespace."
  }

  validation {
    condition = alltrue([
      for key, value in var.vpc_origin.endpoint_lookup_tags :
      key != "" &&
      value != "" &&
      trimspace(key) == key &&
      trimspace(value) == value
    ])
    error_message = "vpc_origin.endpoint_lookup_tags keys and values must be non-empty and must not have leading or trailing whitespace."
  }

  validation {
    condition = (
      var.vpc_origin.http_port > 0 &&
      var.vpc_origin.http_port <= 65535 &&
      var.vpc_origin.https_port > 0 &&
      var.vpc_origin.https_port <= 65535
    )
    error_message = "vpc_origin.http_port and vpc_origin.https_port must be valid TCP ports."
  }

  validation {
    condition     = contains(["http-only", "https-only", "match-viewer"], var.vpc_origin.origin_protocol_policy)
    error_message = "vpc_origin.origin_protocol_policy must be one of http-only, https-only, or match-viewer."
  }

  validation {
    condition     = length(var.vpc_origin.origin_ssl_protocols) > 0 && alltrue([for protocol in var.vpc_origin.origin_ssl_protocols : contains(["TLSv1", "TLSv1.1", "TLSv1.2"], protocol)])
    error_message = "vpc_origin.origin_ssl_protocols must contain CloudFront-supported origin TLS protocols."
  }

  validation {
    condition = (
      var.vpc_origin.origin_keepalive_timeout == null ||
      (var.vpc_origin.origin_keepalive_timeout >= 1 && var.vpc_origin.origin_keepalive_timeout <= 60)
    )
    error_message = "vpc_origin.origin_keepalive_timeout must be between 1 and 60 seconds when set."
  }

  validation {
    condition = (
      var.vpc_origin.origin_read_timeout == null ||
      (var.vpc_origin.origin_read_timeout >= 1 && var.vpc_origin.origin_read_timeout <= 120)
    )
    error_message = "vpc_origin.origin_read_timeout must be between 1 and 120 seconds when set."
  }
}

variable "viewer_certificate_arn" {
  description = "Optional existing ACM certificate ARN in us-east-1 covering every hostname. Leave empty to create and DNS-validate a viewer certificate for the managed public DNS root and wildcard."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = trimspace(var.viewer_certificate_arn) == var.viewer_certificate_arn
    error_message = "viewer_certificate_arn must not have leading or trailing whitespace."
  }
}

variable "viewer_mtls" {
  description = "Optional viewer mTLS configuration. Use an existing CloudFront trust store ID, create one from the public CA certificates in viewer_mtls_ca_bundle_pem, or create one from a BYOCA PEM bundle already stored in S3."
  type = object({
    enabled                        = optional(bool, false)
    mode                           = optional(string, "required")
    existing_trust_store_id        = optional(string, "")
    advertise_trust_store_ca_names = optional(bool, false)
    ignore_certificate_expiry      = optional(bool, false)
    trust_store = optional(object({
      create = optional(bool, false)
      name   = optional(string, "")
      ca_bundle_s3 = optional(object({
        bucket  = optional(string, "")
        key     = optional(string, "")
        region  = optional(string, "us-east-1")
        version = optional(string, "")
      }), {})
      timeouts = optional(object({
        create = optional(string)
        update = optional(string)
        delete = optional(string)
      }))
      tags = optional(map(string), {})
    }), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["required", "optional"], var.viewer_mtls.mode)
    error_message = "viewer_mtls.mode must be either required or optional."
  }

  validation {
    condition     = !var.viewer_mtls.enabled || var.http_version == "http2"
    error_message = "viewer_mtls requires http_version = http2."
  }

  validation {
    condition = !var.viewer_mtls.enabled || (
      (var.viewer_mtls.existing_trust_store_id != "" ? 1 : 0) +
      (var.viewer_mtls.trust_store.create ? 1 : 0)
    ) == 1
    error_message = "viewer_mtls requires exactly one of existing_trust_store_id or trust_store.create = true."
  }

  validation {
    condition = (
      trimspace(var.viewer_mtls.mode) == var.viewer_mtls.mode &&
      trimspace(var.viewer_mtls.existing_trust_store_id) == var.viewer_mtls.existing_trust_store_id &&
      trimspace(var.viewer_mtls.trust_store.name) == var.viewer_mtls.trust_store.name &&
      trimspace(var.viewer_mtls.trust_store.ca_bundle_s3.bucket) == var.viewer_mtls.trust_store.ca_bundle_s3.bucket &&
      trimspace(var.viewer_mtls.trust_store.ca_bundle_s3.key) == var.viewer_mtls.trust_store.ca_bundle_s3.key &&
      trimspace(var.viewer_mtls.trust_store.ca_bundle_s3.region) == var.viewer_mtls.trust_store.ca_bundle_s3.region &&
      trimspace(var.viewer_mtls.trust_store.ca_bundle_s3.version) == var.viewer_mtls.trust_store.ca_bundle_s3.version
    )
    error_message = "viewer_mtls string fields must not have leading or trailing whitespace."
  }

  validation {
    condition = !var.viewer_mtls.trust_store.create || (
      nonsensitive(trimspace(var.viewer_mtls_ca_bundle_pem) != "") ||
      (
        var.viewer_mtls.trust_store.ca_bundle_s3.bucket != "" &&
        var.viewer_mtls.trust_store.ca_bundle_s3.key != "" &&
        var.viewer_mtls.trust_store.ca_bundle_s3.region != ""
      )
    )
    error_message = "viewer_mtls.trust_store.create requires either viewer_mtls_ca_bundle_pem or ca_bundle_s3 bucket, key, and region."
  }

  validation {
    condition = nonsensitive(trimspace(var.viewer_mtls_ca_bundle_pem) == "") || (
      var.viewer_mtls.enabled &&
      var.viewer_mtls.trust_store.create &&
      var.viewer_mtls.existing_trust_store_id == ""
    )
    error_message = "viewer_mtls_ca_bundle_pem can only be set when viewer_mtls is enabled and viewer_mtls.trust_store.create is true."
  }
}

variable "viewer_mtls_ca_bundle_pem" {
  description = "PEM-encoded public CA certificate bundle to upload to a module-managed S3 object for a created CloudFront viewer mTLS trust store. This value is stored in Terraform state; do not pass private keys or confidential material. Leave empty when using an existing trust store or an existing S3 CA bundle."
  type        = string
  default     = ""
  nullable    = false
  sensitive   = true

  validation {
    condition = nonsensitive(trimspace(var.viewer_mtls_ca_bundle_pem) == "") || (
      nonsensitive(strcontains(var.viewer_mtls_ca_bundle_pem, "-----BEGIN CERTIFICATE-----")) &&
      nonsensitive(strcontains(var.viewer_mtls_ca_bundle_pem, "-----END CERTIFICATE-----"))
    )
    error_message = "viewer_mtls_ca_bundle_pem must contain one or more PEM certificates."
  }
}

variable "preserve_viewer_host_header" {
  description = "Whether CloudFront forwards the viewer Host header to Ryvn. Keep true for current Ryvn Gateway routing by public hostname."
  type        = bool
  default     = true
  nullable    = false
}

variable "cache_policy_id" {
  description = "CloudFront cache policy ID. Leave empty to use cache_policy_name."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = trimspace(var.cache_policy_id) == var.cache_policy_id
    error_message = "cache_policy_id must not have leading or trailing whitespace."
  }
}

variable "cache_policy_name" {
  description = "Managed or custom CloudFront cache policy name used when cache_policy_id is empty."
  type        = string
  default     = "Managed-CachingDisabled"
  nullable    = false

  validation {
    condition = var.cache_policy_id != "" ? (
      var.cache_policy_name == ""
      ) : (
      var.cache_policy_name != "" &&
      trimspace(var.cache_policy_name) == var.cache_policy_name
    )
    error_message = "Set either cache_policy_id or cache_policy_name, not both. cache_policy_name must be non-empty when cache_policy_id is empty and must not have leading or trailing whitespace."
  }
}

variable "origin_request_policy_id" {
  description = "CloudFront origin request policy ID. Leave empty to use origin_request_policy_name or the module's preserve-host default."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = trimspace(var.origin_request_policy_id) == var.origin_request_policy_id
    error_message = "origin_request_policy_id must not have leading or trailing whitespace."
  }

  validation {
    condition     = !(var.origin_request_policy_id != "" && var.origin_request_policy_name != "")
    error_message = "Set either origin_request_policy_id or origin_request_policy_name, not both."
  }
}

variable "origin_request_policy_name" {
  description = "Managed or custom CloudFront origin request policy name used when origin_request_policy_id is empty. Defaults to Managed-AllViewer when preserving Host, otherwise Managed-AllViewerExceptHostHeader."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = trimspace(var.origin_request_policy_name) == var.origin_request_policy_name
    error_message = "origin_request_policy_name must not have leading or trailing whitespace."
  }
}

variable "response_headers_policy_id" {
  description = "CloudFront response headers policy ID to attach to the default cache behavior. Leave empty to use response_headers_policy_name or attach no response headers policy."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = trimspace(var.response_headers_policy_id) == var.response_headers_policy_id
    error_message = "response_headers_policy_id must not have leading or trailing whitespace."
  }

  validation {
    condition     = !(var.response_headers_policy_id != "" && var.response_headers_policy_name != "")
    error_message = "Set either response_headers_policy_id or response_headers_policy_name, not both."
  }
}

variable "response_headers_policy_name" {
  description = "Managed or custom CloudFront response headers policy name to attach to the default cache behavior when response_headers_policy_id is empty."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = trimspace(var.response_headers_policy_name) == var.response_headers_policy_name
    error_message = "response_headers_policy_name must not have leading or trailing whitespace."
  }
}

variable "allowed_methods" {
  description = "HTTP methods CloudFront accepts from viewers."
  type        = list(string)
  default     = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
  nullable    = false

  validation {
    condition = (
      length(var.allowed_methods) > 0 &&
      alltrue([for method in var.allowed_methods : contains(["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"], method)])
    )
    error_message = "allowed_methods must contain CloudFront-supported HTTP methods."
  }
}

variable "cached_methods" {
  description = "HTTP methods CloudFront caches. Must be a subset of allowed_methods."
  type        = list(string)
  default     = ["GET", "HEAD", "OPTIONS"]
  nullable    = false

  validation {
    condition = (
      length(var.cached_methods) > 0 &&
      alltrue([for method in var.cached_methods : contains(["GET", "HEAD", "OPTIONS"], method)]) &&
      alltrue([for method in var.cached_methods : contains(var.allowed_methods, method)])
    )
    error_message = "cached_methods must contain GET, HEAD, or OPTIONS values and must be a subset of allowed_methods."
  }
}

variable "compress" {
  description = "Whether CloudFront automatically compresses eligible responses."
  type        = bool
  default     = true
  nullable    = false
}

variable "price_class" {
  description = "CloudFront price class."
  type        = string
  default     = "PriceClass_100"
  nullable    = false

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be one of PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}

variable "http_version" {
  description = "Maximum HTTP version CloudFront supports for viewers."
  type        = string
  default     = "http2"
  nullable    = false

  validation {
    condition     = contains(["http1.1", "http2", "http2and3", "http3"], var.http_version)
    error_message = "http_version must be one of http1.1, http2, http2and3, or http3."
  }
}

variable "minimum_protocol_version" {
  description = "Minimum TLS protocol version for the CloudFront viewer certificate."
  type        = string
  default     = "TLSv1.2_2021"
  nullable    = false

  validation {
    condition     = contains(["TLSv1", "TLSv1_2016", "TLSv1.1_2016", "TLSv1.2_2018", "TLSv1.2_2019", "TLSv1.2_2021", "TLSv1.2_2025", "TLSv1.3_2025"], var.minimum_protocol_version)
    error_message = "minimum_protocol_version must be one of TLSv1, TLSv1_2016, TLSv1.1_2016, TLSv1.2_2018, TLSv1.2_2019, TLSv1.2_2021, TLSv1.2_2025, or TLSv1.3_2025."
  }
}

variable "origin_ssl_protocols" {
  description = "TLS protocol versions CloudFront may use to connect to the Ryvn origin."
  type        = set(string)
  default     = ["TLSv1.2"]
  nullable    = false

  validation {
    condition     = length(var.origin_ssl_protocols) > 0 && alltrue([for protocol in var.origin_ssl_protocols : contains(["TLSv1", "TLSv1.1", "TLSv1.2"], protocol)])
    error_message = "origin_ssl_protocols must contain CloudFront-supported origin TLS protocols."
  }
}

variable "origin_keepalive_timeout" {
  description = "CloudFront custom origin keepalive timeout, in seconds."
  type        = number
  default     = 5
  nullable    = false

  validation {
    condition     = var.origin_keepalive_timeout >= 1 && var.origin_keepalive_timeout <= 60
    error_message = "origin_keepalive_timeout must be between 1 and 60 seconds."
  }
}

variable "origin_read_timeout" {
  description = "CloudFront custom origin read timeout, in seconds."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.origin_read_timeout >= 1 && var.origin_read_timeout <= 120
    error_message = "origin_read_timeout must be between 1 and 120 seconds."
  }
}

variable "origin_shield" {
  description = "Optional CloudFront origin shield configuration for the single Ryvn origin."
  type = object({
    enabled              = optional(bool, false)
    origin_shield_region = optional(string, "")
  })
  default  = {}
  nullable = false

  validation {
    condition     = trimspace(var.origin_shield.origin_shield_region) == var.origin_shield.origin_shield_region
    error_message = "origin_shield.origin_shield_region must not have leading or trailing whitespace."
  }

  validation {
    condition     = !var.origin_shield.enabled || var.origin_shield.origin_shield_region != ""
    error_message = "origin_shield.origin_shield_region is required when origin_shield.enabled = true."
  }
}

variable "connection_attempts" {
  description = "Number of times CloudFront attempts to connect to the origin."
  type        = number
  default     = 3
  nullable    = false

  validation {
    condition     = var.connection_attempts >= 1 && var.connection_attempts <= 3
    error_message = "connection_attempts must be between 1 and 3."
  }
}

variable "connection_timeout" {
  description = "Number of seconds CloudFront waits when connecting to the origin."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.connection_timeout >= 1 && var.connection_timeout <= 10
    error_message = "connection_timeout must be between 1 and 10 seconds."
  }
}

variable "enabled" {
  description = "Whether the CloudFront distribution is enabled."
  type        = bool
  default     = true
  nullable    = false
}

variable "ipv6_enabled" {
  description = "Whether CloudFront serves IPv6 viewer traffic."
  type        = bool
  default     = true
  nullable    = false
}

variable "comment" {
  description = "Optional CloudFront distribution comment. Defaults to a generated comment when empty."
  type        = string
  default     = ""
  nullable    = false
}

variable "wait_for_deployment" {
  description = "Whether Terraform waits for CloudFront distribution deployment to finish."
  type        = bool
  default     = false
  nullable    = false
}

variable "retain_on_delete" {
  description = "Whether Terraform disables the CloudFront distribution instead of deleting it on destroy."
  type        = bool
  default     = false
  nullable    = false
}

variable "custom_error_responses" {
  description = "Optional CloudFront custom error responses for the distribution."
  type = list(object({
    error_caching_min_ttl = optional(number)
    error_code            = number
    response_code         = optional(number)
    response_page_path    = optional(string)
  }))
  default  = []
  nullable = false

  validation {
    condition = alltrue([
      for response in var.custom_error_responses :
      response.error_code >= 400 &&
      response.error_code <= 599 &&
      (response.response_code == null || (response.response_code >= 200 && response.response_code <= 599)) &&
      (response.response_page_path == null || startswith(response.response_page_path, "/")) &&
      (response.error_caching_min_ttl == null || response.error_caching_min_ttl >= 0)
    ])
    error_message = "custom_error_responses entries must use 4xx/5xx error_code values, optional 2xx-5xx response_code values, slash-prefixed response_page_path values, and non-negative error_caching_min_ttl values."
  }
}

variable "geo_restriction" {
  description = "CloudFront geo restriction configuration."
  type = object({
    restriction_type = optional(string, "none")
    locations        = optional(set(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["none", "whitelist", "blacklist"], var.geo_restriction.restriction_type)
    error_message = "geo_restriction.restriction_type must be one of none, whitelist, or blacklist."
  }

  validation {
    condition     = var.geo_restriction.restriction_type == "none" || length(var.geo_restriction.locations) > 0
    error_message = "geo_restriction.locations must be non-empty when restriction_type is whitelist or blacklist."
  }
}

variable "dns" {
  description = "Optional Route53 alias record creation for hostnames."
  type = object({
    enabled                = optional(bool, false)
    create_ipv4_alias      = optional(bool, true)
    create_ipv6_alias      = optional(bool, true)
    evaluate_target_health = optional(bool, false)
    allow_overwrite        = optional(bool, true)
  })
  default  = {}
  nullable = false

  validation {
    condition     = !var.dns.enabled || var.dns.create_ipv4_alias || var.dns.create_ipv6_alias
    error_message = "At least one of dns.create_ipv4_alias or dns.create_ipv6_alias must be true when dns.enabled = true."
  }
}

variable "monitoring" {
  description = "Optional CloudFront realtime metrics monitoring subscription."
  type = object({
    enabled                              = optional(bool, false)
    realtime_metrics_subscription_status = optional(string, "Enabled")
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["Enabled", "Disabled"], var.monitoring.realtime_metrics_subscription_status)
    error_message = "monitoring.realtime_metrics_subscription_status must be Enabled or Disabled."
  }
}

variable "standard_logging_v2" {
  description = "Optional CloudFront standard logging v2 destination using CloudWatch log delivery."
  type = object({
    enabled                   = optional(bool, false)
    name                      = optional(string, "")
    destination_resource_arn  = optional(string, "")
    delivery_destination_type = optional(string, "S3")
    output_format             = optional(string)
    field_delimiter           = optional(string)
    record_fields             = optional(list(string))
    s3_delivery_configuration = optional(object({
      enable_hive_compatible_path = optional(bool)
      suffix_path                 = optional(string)
    }))
  })
  default  = {}
  nullable = false

  validation {
    condition = (
      trimspace(var.standard_logging_v2.name) == var.standard_logging_v2.name &&
      trimspace(var.standard_logging_v2.destination_resource_arn) == var.standard_logging_v2.destination_resource_arn &&
      trimspace(var.standard_logging_v2.delivery_destination_type) == var.standard_logging_v2.delivery_destination_type
    )
    error_message = "standard_logging_v2 string fields must not have leading or trailing whitespace."
  }

  validation {
    condition     = !var.standard_logging_v2.enabled || var.standard_logging_v2.destination_resource_arn != ""
    error_message = "standard_logging_v2.destination_resource_arn is required when standard_logging_v2.enabled = true."
  }
}

variable "waf" {
  description = "Optional CloudFront-scoped AWS WAFv2 WebACL configuration for common Ryvn edge controls. Set waf.allowed_ips for an IP allowlist, waf.managed_rules = true for AWS's Common Rule Set, or waf.managed_rule_groups for additional AWS managed rule groups. Use waf_advanced for raw upstream WAF module inputs. The WebACL is created automatically when WAF content is configured unless waf.enabled = false."
  type = object({
    enabled = optional(bool)

    allowed_ips         = optional(set(string), [])
    managed_rules       = optional(bool, false)
    managed_rule_groups = optional(set(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for cidr in var.waf.allowed_ips :
      trimspace(cidr) == cidr &&
      can(cidrhost(cidr, 0)) &&
      !endswith(cidr, "/0")
    ])
    error_message = "waf.allowed_ips entries must be valid IPv4 or IPv6 CIDRs with no leading or trailing whitespace, and must not be /0 (which would allow the entire internet)."
  }

  validation {
    condition = alltrue([
      for name in var.waf.managed_rule_groups :
      trimspace(name) == name &&
      can(regex("^[A-Za-z0-9_-]+$", name))
    ])
    error_message = "waf.managed_rule_groups entries must be AWS managed rule group names with no whitespace, such as AWSManagedRulesCommonRuleSet."
  }
}

variable "waf_advanced" {
  description = "Advanced passthrough inputs for the upstream aws-ss/wafv2/aws module. These names intentionally match the child module, except this wrapper still fixes scope, region, association wiring, and resource_arn for CloudFront."
  type = object({
    name        = optional(string, "")
    description = optional(string)

    default_action = optional(string, "allow")
    default_custom_response = optional(object({
      response_code            = optional(number, 403)
      custom_response_body_key = optional(string)
      response_header = optional(list(object({
        name  = string
        value = string
      })), [])
    }))
    association_config = optional(map(any))

    visibility_config = optional(object({
      cloudwatch_metrics_enabled = optional(bool, true)
      metric_name                = optional(string, "")
      sampled_requests_enabled   = optional(bool, true)
    }), {})

    custom_response_body = optional(list(object({
      content      = string
      content_type = string
      key          = string
    })), [])
    captcha_config   = optional(number, 300)
    challenge_config = optional(number, 300)
    token_domains    = optional(list(string), [])
    rule             = optional(any, [])
    tags             = optional(map(string))

    enabled_logging_configuration = optional(bool, false)
    log_destination_configs       = optional(string)
    redacted_fields               = optional(list(any))
    logging_filter                = optional(any)
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["allow", "block"], var.waf_advanced.default_action)
    error_message = "waf_advanced.default_action must be either allow or block."
  }

  validation {
    condition = (
      trimspace(var.waf_advanced.name) == var.waf_advanced.name &&
      (var.waf_advanced.description == null ? true : trimspace(var.waf_advanced.description) == var.waf_advanced.description) &&
      trimspace(var.waf_advanced.visibility_config.metric_name) == var.waf_advanced.visibility_config.metric_name &&
      (var.waf_advanced.log_destination_configs == null ? true : trimspace(var.waf_advanced.log_destination_configs) == var.waf_advanced.log_destination_configs)
    )
    error_message = "waf_advanced string fields must not have leading or trailing whitespace."
  }

  validation {
    condition     = !var.waf_advanced.enabled_logging_configuration || (var.waf_advanced.log_destination_configs != null && var.waf_advanced.log_destination_configs != "")
    error_message = "waf_advanced.log_destination_configs is required when waf_advanced.enabled_logging_configuration = true."
  }
}

variable "web_acl_arn" {
  description = "Existing AWS WAFv2 WebACL ARN to attach to the CloudFront distribution. CloudFront accepts one CLOUDFRONT-scoped WebACL ARN; leave empty to attach no WebACL."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = trimspace(var.web_acl_arn) == var.web_acl_arn
    error_message = "web_acl_arn must not have leading or trailing whitespace."
  }

  validation {
    condition     = var.web_acl_arn == "" || can(regex("^arn:aws[a-zA-Z-]*:wafv2:us-east-1:[0-9]{12}:global/webacl/.+/.+$", var.web_acl_arn))
    error_message = "web_acl_arn must be empty or a CloudFront-scoped AWS WAFv2 WebACL ARN from us-east-1."
  }

  validation {
    condition = var.web_acl_arn == "" || !(
      var.waf.enabled == true ||
      (
        var.waf.enabled == null &&
        (
          length(var.waf.allowed_ips) > 0 ||
          var.waf.managed_rules ||
          length(var.waf.managed_rule_groups) > 0 ||
          var.waf_advanced.default_action == "block" ||
          trimspace(var.waf_advanced.visibility_config.metric_name) != "" ||
          var.waf_advanced.enabled_logging_configuration ||
          trimspace(var.waf_advanced.name) != "" ||
          var.waf_advanced.description != null ||
          var.waf_advanced.tags != null ||
          length(var.waf_advanced.rule) > 0 ||
          var.waf_advanced.default_custom_response != null ||
          var.waf_advanced.association_config != null ||
          length(var.waf_advanced.custom_response_body) > 0 ||
          length(var.waf_advanced.token_domains) > 0 ||
          var.waf_advanced.redacted_fields != null ||
          var.waf_advanced.logging_filter != null
        )
      )
    )
    error_message = "Set either web_acl_arn or waf configuration, not both. CloudFront accepts one WebACL per distribution."
  }
}

variable "tags" {
  description = "Tags applied to AWS resources that support tagging."
  type        = map(string)
  default     = {}
  nullable    = false
}

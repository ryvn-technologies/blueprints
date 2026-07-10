# CloudFront Edge

Put AWS CloudFront in front of a Ryvn origin. Public traffic enters through CloudFront and optional AWS WAF, then CloudFront forwards requests to either a public Ryvn Gateway origin with origin mTLS or a CloudFront VPC origin without origin mTLS.

## What this does

For the hostnames you configure, this module:

1. Creates a CloudFront distribution with your hostnames as aliases.
2. Creates and DNS-validates an ACM viewer certificate in `us-east-1` for the environment public domain apex and wildcard.
3. Forwards to a public custom origin with HTTPS-only origin mTLS, or to a CloudFront VPC origin.
4. Forwards the viewer `Host` header by default for current Ryvn Gateway routing.
5. Optionally creates Route53 alias records.
6. Optionally enables viewer mTLS with an existing trust store or BYOCA S3 CA bundle.
7. Optionally creates a CloudFront-scoped AWS WAFv2 WebACL through `aws-ss/wafv2/aws`, or attaches an existing WebACL ARN.
8. Optionally attaches response headers policy, custom error responses, origin shield, monitoring, and standard logging v2.

The public-origin mTLS client certificate is referenced by ARN only. Do not pass private keys into Terraform variables. CloudFront origin mTLS is not used for VPC origins; VPC mode relies on CloudFront VPC-origin network isolation and the origin's TLS posture.

## Multiple installations

You can install this module more than once in the same environment to give
different hostnames different CloudFront distributions and WAF rules. Separate
installations must not reuse the same exact `hostnames` value because
CloudFront rejects duplicate alternate domain names across distributions. A
wildcard alias can overlap a more-specific alias in another distribution, and
CloudFront routes requests to the more-specific match. Leaving `hostnames`
empty uses the managed public DNS root apex and wildcard, so only one
installation in an account can safely use that default.

## Before you start

### Ryvn origin requirements

For public origin mode, Ryvn must provide:

- a stable public origin hostname
- Gateway routes for every public hostname, or another agreed routing mode
- an origin/server TLS certificate valid for the forwarded host behavior
- a trusted CA bundle that validates CloudFront's origin client certificate
- direct-origin rejection for requests without the trusted client certificate

For VPC origin mode, Ryvn or the edge owner must provide:

- a CloudFront-supported VPC origin endpoint, such as an internal ALB, NLB, or EC2 instance
- security groups and private subnets that allow CloudFront VPC origin traffic
- an origin/server TLS posture compatible with `vpc_origin.origin_protocol_policy`

With the default `preserve_viewer_host_header = true`, CloudFront connects to the configured origin hostname but forwards the viewer `Host` header, such as `api.example.com`. The Ryvn Gateway certificate must be valid for that public hostname.

### AWS requirements

- CloudFront, CloudFront-scoped WAF, CloudFront ACM certificates, and CloudFront standard logging v2 API calls use `us-east-1`.
- The Route53 public hosted zone for the managed public DNS root must be visible to the AWS credentials running Terraform when using the default managed viewer certificate or `dns.enabled = true`.
- If `viewer_certificate_arn` is set, it must be an ACM certificate in `us-east-1` that covers every hostname. Leave it empty for the default managed certificate.
- Viewer mTLS requires `http_version = "http2"` and a CloudFront trust store.
- Public origin mode requires `origin_client_certificate_arn`, an ACM certificate in `us-east-1` suitable for TLS client authentication.
- ACM public certificates are fine for viewer TLS. For origin mTLS client certificates, use an imported or private CA issued certificate rather than an ACM public certificate.

### Terraform executor IAM permissions

To support every module feature, grant the Terraform executor these IAM actions:

```text
acm:AddTagsToCertificate
acm:DeleteCertificate
acm:DescribeCertificate
acm:ListTagsForCertificate
acm:RemoveTagsFromCertificate
acm:RequestCertificate
cloudfront:AllowVendedLogDeliveryForResource
cloudfront:AssociateDistributionWebACL
cloudfront:CreateConnectionGroup
cloudfront:CreateDistribution
cloudfront:CreateMonitoringSubscription
cloudfront:CreateTrustStore
cloudfront:CreateVpcOrigin
cloudfront:DeleteDistribution
cloudfront:DeleteMonitoringSubscription
cloudfront:DeleteTrustStore
cloudfront:DeleteVpcOrigin
cloudfront:DisassociateDistributionWebACL
cloudfront:GetCachePolicy
cloudfront:GetCachePolicyConfig
cloudfront:GetDistribution
cloudfront:GetDistributionConfig
cloudfront:GetMonitoringSubscription
cloudfront:GetOriginRequestPolicy
cloudfront:GetOriginRequestPolicyConfig
cloudfront:GetResponseHeadersPolicy
cloudfront:GetResponseHeadersPolicyConfig
cloudfront:GetTrustStore
cloudfront:GetVpcOrigin
cloudfront:ListCachePolicies
cloudfront:ListOriginRequestPolicies
cloudfront:ListResponseHeadersPolicies
cloudfront:ListTagsForResource
cloudfront:ListTrustStores
cloudfront:ListVpcOrigins
cloudfront:TagResource
cloudfront:UntagResource
cloudfront:UpdateDistribution
cloudfront:UpdateTrustStore
cloudfront:UpdateVpcOrigin
elasticloadbalancing:DescribeLoadBalancers
elasticloadbalancing:DescribeTags
firehose:TagDeliveryStream
iam:CreateServiceLinkedRole
logs:CreateDelivery
logs:DeleteDelivery
logs:DeleteDeliveryDestination
logs:DeleteDeliverySource
logs:DescribeLogGroups
logs:DescribeResourcePolicies
logs:GetDelivery
logs:GetDeliveryDestination
logs:GetDeliverySource
logs:ListTagsForResource
logs:PutDeliveryDestination
logs:PutDeliverySource
logs:PutResourcePolicy
logs:TagResource
logs:UntagResource
logs:UpdateDeliveryConfiguration
route53:ChangeResourceRecordSets
route53:GetChange
route53:GetHostedZone
route53:ListHostedZones
route53:ListHostedZonesByName
route53:ListResourceRecordSets
s3:CreateBucket
s3:DeleteBucket
s3:DeleteObject
s3:GetBucketEncryption
s3:GetBucketPolicy
s3:GetBucketPublicAccessBlock
s3:GetBucketTagging
s3:GetBucketVersioning
s3:GetObject
s3:GetObjectTagging
s3:ListBucket
s3:PutBucketEncryption
s3:PutBucketPolicy
s3:PutBucketPublicAccessBlock
s3:PutBucketTagging
s3:PutBucketVersioning
s3:PutObject
s3:PutObjectTagging
sts:GetCallerIdentity
tag:GetResources
wafv2:CheckCapacity
wafv2:CreateIPSet
wafv2:CreateWebACL
wafv2:DeleteIPSet
wafv2:DeleteLoggingConfiguration
wafv2:DeleteWebACL
wafv2:GetIPSet
wafv2:GetLoggingConfiguration
wafv2:GetWebACL
wafv2:ListIPSets
wafv2:ListLoggingConfigurations
wafv2:ListTagsForResource
wafv2:ListWebACLs
wafv2:PutLoggingConfiguration
wafv2:TagResource
wafv2:UntagResource
wafv2:UpdateIPSet
wafv2:UpdateWebACL
```

## Public origin configuration

This is the default `origin_type = "public"` mode. The Ryvn
`cloudfront-edge` blueprint injects `managed_public_dns_root` from
`.ryvn.env.state.public_domain.name`, and the module derives the aliases and
origin hostname from that value:

```yaml
origin_client_certificate_arn: "arn:aws:acm:us-east-1:123456789012:certificate/..."
```

By default, public origin mode uses `origin.<managed_public_dns_root>`, so a Ryvn
environment public domain of `example.com` resolves to `origin.example.com`.

## Internal origin configuration

Internal mode uses a CloudFront VPC origin and does not accept
`origin_client_certificate_arn`. The Ryvn `cloudfront-edge` blueprint injects
`managed_private_dns_root` from `.ryvn.env.state.internal_domain.name`, and the
module derives `internal-origin.<managed_private_dns_root>` from that value.

Create a CloudFront VPC origin by looking up the internal load balancer from
AWS tags:

```yaml
origin_type: "internal"

vpc_origin:
  create: true
  endpoint_lookup_tags:
    elbv2.k8s.aws/cluster: "ryvn-eks-example"
    service.k8s.aws/stack: "internal-ingress-nginx/internal-ingress-nginx-controller-internal"
    service.k8s.aws/resource: "LoadBalancer"
  origin_protocol_policy: "https-only"
```

Alternatively, pass the endpoint ARN directly:

```yaml
origin_type: "internal"

vpc_origin:
  create: true
  endpoint_arn: "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/internal/..."
```

Use an existing CloudFront VPC origin:

```yaml
origin_type: "internal"

vpc_origin:
  existing_vpc_origin_id: "vo_abc123"
```

## Hardening and observability

Attach an existing response headers policy by ID or name:

```yaml
response_headers_policy_id: "67f7725c-6f97-4210-82d7-5512b31e9d03"
```

Add custom error responses and origin shield:

```yaml
custom_error_responses:
  - error_code: 403
    response_code: 403
    response_page_path: "/errors/403.html"
    error_caching_min_ttl: 30

origin_shield:
  enabled: true
  origin_shield_region: "us-east-1"
```

Enable CloudFront realtime metrics and standard logging v2:

```yaml
monitoring:
  enabled: true

standard_logging_v2:
  enabled: true
  name: "acme-prod-edge-logs"
  destination_resource_arn: "arn:aws:s3:::acme-cloudfront-logs/cloudfront"
  delivery_destination_type: "S3"
  output_format: "parquet"
  s3_delivery_configuration:
    enable_hive_compatible_path: true
    suffix_path: "{DistributionId}/{yyyy}/{MM}/{dd}/{HH}"
```

## Viewer certificate

By default, the module uses `managed_public_dns_root`, looks up the Route53 public
hosted zone by that name, requests an ACM certificate in `us-east-1`, and
creates DNS validation records in that zone. The Ryvn `cloudfront-edge`
blueprint injects `managed_public_dns_root` from the environment public domain.

```yaml
origin_client_certificate_arn: "arn:aws:acm:us-east-1:123456789012:certificate/..."
```

The managed certificate uses the public domain apex as its primary name and
adds the managed public DNS root wildcard as the SAN. `hostnames` defaults to
the same apex and wildcard aliases. When the module creates the viewer
certificate or Route53 records, `hostnames` must be the apex, the wildcard, or
one-label subdomains covered by the managed wildcard certificate and public
zone. If you pass `viewer_certificate_arn` and leave `dns.enabled = false`,
`hostnames` may be any valid CloudFront aliases covered by that certificate.

## Viewer mTLS

Use an existing CloudFront trust store:

```yaml
viewer_mtls:
  enabled: true
  mode: "required"
  existing_trust_store_id: "ts_abc123"
```

Or create a trust store from a BYOCA PEM bundle already uploaded to S3:

```yaml
viewer_mtls:
  enabled: true
  mode: "required"
  trust_store:
    create: true
    name: "acme-prod-viewer-mtls"
    ca_bundle_s3:
      bucket: "acme-security-artifacts"
      key: "cloudfront/client-ca-bundle.pem"
      region: "us-east-1"
      version: "..."
```

Or let the module upload the CA bundle to a private, versioned S3 bucket and
wire that object version into the trust store:

```yaml
viewer_mtls_ca_bundle_pem: |
  -----BEGIN CERTIFICATE-----
  ...
  -----END CERTIFICATE-----

viewer_mtls:
  enabled: true
  mode: "required"
  trust_store:
    create: true
```

When `viewer_mtls_ca_bundle_pem` is set, the module creates the S3 bucket,
uploads `viewer-mtls/ca-bundle.pem`, creates the CloudFront trust store, and
wires the trust store to the distribution. If `trust_store.name` is empty, the
module generates one. This input is for public CA certificate material only.
Terraform stores the PEM in state, so use an existing trust store or S3 bundle
if the bundle must stay out of Terraform state.

## Route53 DNS

When Route53 owns the public zone, enable alias records. The module uses the
same `managed_public_dns_root` hosted-zone lookup used for certificate validation:

```yaml
dns:
  enabled: true
  create_ipv4_alias: true
  create_ipv6_alias: true
```

When another DNS provider owns the zone, pass `viewer_certificate_arn`, leave
DNS disabled, and use:

```bash
terraform output required_dns_records
```

Each hostname should point at the CloudFront distribution name. Apex records
need an ALIAS/ANAME-style record if your DNS provider supports one:

```text
acme.com ALIAS/ANAME d123456abcdef8.cloudfront.net
*.acme.com CNAME d123456abcdef8.cloudfront.net
```

## WAF

CloudFront accepts one WebACL per distribution. This module gives you one WAF
surface:

- `waf` creates and attaches a CloudFront-scoped WebACL for common Ryvn edge controls.
- `waf_advanced` adds raw upstream WAF module inputs for custom rules, responses, token domains, and logging filters.
- `web_acl_arn` attaches an externally managed WebACL instead.

Leave `waf.enabled` unset for normal use. The module creates a WebACL
automatically when `waf` or `waf_advanced` has content. Set
`waf.enabled = false` only as a temporary kill switch; set `waf.enabled = true`
only when you intentionally want to create an otherwise empty WebACL.

### Simple IP allowlist

To lock the edge down to a known set of networks, set `waf.allowed_ips` to a
list of CIDR blocks. That is the entire configuration:

```yaml
waf:
  allowed_ips:
    - "203.0.113.0/24"
    - "198.51.100.7/32"
```

The module creates a CloudFront-scoped WebACL that blocks by default and allows
only these CIDRs, building the IP set and allow rule for you and attaching the
WebACL to the distribution. Requests from any other address get a WAF `403`.

IPv4 and IPv6 may be mixed; because WAFv2 IP sets are single-family, the module
creates one IP set per address family:

```yaml
waf:
  allowed_ips:
    - "203.0.113.0/24"
    - "2001:db8::/48"
```

### Managed rules (OWASP) plus an IP allowlist

To add AWS's Common Rule Set before the allowlist, set `managed_rules: true` in
the same `waf` block:

```yaml
waf:
  allowed_ips:
    - "203.0.113.0/24"
  managed_rules: true
```

There is no AWS managed group literally named "OWASP";
`AWSManagedRulesCommonRuleSet` is AWS's core rule set that covers the OWASP-style
protections. `managed_rules: true` expands to an enforced
`AWSManagedRulesCommonRuleSet` rule with `vendor_name = "AWS"`.

Add extra AWS managed groups without writing raw WAF rule statements:

```yaml
waf:
  allowed_ips:
    - "203.0.113.0/24"
  managed_rules: true
  managed_rule_groups:
    - AWSManagedRulesKnownBadInputsRuleSet
    - AWSManagedRulesSQLiRuleSet
```

When `waf.allowed_ips` is set, the module forces the WebACL default action to
`block` and appends the allowlist allow rules after custom and generated managed
rules. That ordering matters: managed rules evaluate first and can block
malicious requests from allowlisted IPs, then the allow rule lets clean
allowlisted traffic through, and everything else falls through to the default
block. The result:

- allowlisted IP, clean request → allowed
- allowlisted IP, malicious request → blocked by the managed rule
- any other IP → blocked

### Existing WebACL

Attach an externally managed CloudFront-scoped WebACL ARN:

```yaml
web_acl_arn: "arn:aws:wafv2:us-east-1:123456789012:global/webacl/acme-prod-edge/..."
```

### Advanced WebACL passthrough

Create a WebACL in this module through the `aws-ss/wafv2/aws` child module:

```yaml
waf_advanced:
  name: acme-prod-edge-waf
  default_action: allow

  rule:
    - name: AWSManagedRulesCommonRuleSet
      priority: 10
      override_action: count
      managed_rule_group_statement:
        name: AWSManagedRulesCommonRuleSet
        vendor_name: AWS
      visibility_config:
        cloudwatch_metrics_enabled: true
        metric_name: AWSManagedRulesCommonRuleSet
        sampled_requests_enabled: true
```

The `waf_advanced` object is an explicit passthrough to the upstream module's
input shape for fields this wrapper does not reserve. Common upstream fields
such as `name`, `description`, `default_action`, `visibility_config`,
`custom_response_body`, `captcha_config`, `challenge_config`, `token_domains`,
`rule`, `tags`, `enabled_logging_configuration`, `log_destination_configs`,
`redacted_fields`, and `logging_filter` belong here.
Ryvn still fixes CloudFront-specific wiring: `scope = "CLOUDFRONT"`,
`region = "us-east-1"`, `enabled_web_acl_association = false`,
`resource_arn = []`, and attaches the created ARN through the CloudFront
distribution.

The wrapper also defaults `cloudwatch_metrics_enabled = true` and
`sampled_requests_enabled = true` for rule-level `visibility_config` blocks so
simple rules only need to provide a rule `metric_name`.

For an allowlist, prefer `waf.allowed_ips` above. To block specific CIDRs (a
blocklist) or build any other custom IP-set rule, create or reference a WAF IP
set outside this wrapper and pass its ARN in the raw upstream rule shape:

```yaml
waf_advanced:
  default_action: allow
  visibility_config:
    metric_name: acme-prod-edge-waf

  rule:
    - name: block-listed-ips
      priority: 10
      action: block
      ip_set_reference_statement:
        arn: "arn:aws:wafv2:us-east-1:123456789012:global/ipset/acme-prod-blocked/..."
      visibility_config:
        metric_name: block-listed-ips
```

The simple `waf.allowed_ips` path is the only path where this wrapper creates
WAF IP sets for you. The advanced path is intentionally passthrough.

The WebACL must use `scope = "CLOUDFRONT"` and be managed through the
`us-east-1` AWS provider.

## Inputs

Required by mode:

| Name | Description |
|------|-------------|
| `origin_client_certificate_arn` | ACM client certificate ARN in `us-east-1` for public-origin CloudFront origin mTLS. |
| `vpc_origin` | VPC origin configuration when `origin_type = "internal"` or `origin_type = "vpc"`. Use `endpoint_lookup_tags` or `endpoint_arn` when creating a VPC origin, or `existing_vpc_origin_id` to reuse one. |

Common optional inputs:

| Name | Default | Description |
|------|---------|-------------|
| `name_prefix` | `ryvn-cloudfront-edge` | Optional prefix for generated AWS resource names. |
| `managed_public_dns_root` | required | Managed public DNS root. The Ryvn blueprint injects `.ryvn.env.state.public_domain.name`. |
| `managed_private_dns_root` | empty | Managed private DNS root. Required for internal/VPC origins when `vpc_origin.domain_name` is empty; the Ryvn blueprint injects `.ryvn.env.state.internal_domain.name`. |
| `hostnames` | apex and wildcard | CloudFront aliases. Empty serves the managed public DNS root and wildcard. Do not reuse the same exact alias in parallel installations. |
| `origin_type` | `public` | `public` for origin mTLS custom origin, or `internal` for CloudFront VPC origin. `vpc` is accepted as an alias for `internal`. |
| `origin_hostname` | `origin.<managed_public_dns_root>` | Override for the public Ryvn origin hostname. |
| `origin_port` | `443` | HTTPS port for CloudFront-to-public-origin traffic. |
| `preserve_viewer_host_header` | `true` | Uses `Managed-AllViewer` origin request policy so Ryvn routes on the public hostname. |
| `cache_policy_name` | `Managed-CachingDisabled` | API-style default cache policy. |
| `response_headers_policy_id` | empty | Existing CloudFront response headers policy to attach. |
| `viewer_mtls` | disabled | Optional viewer mTLS using an existing trust store ID, a module-uploaded CA bundle, or an existing S3 CA bundle. |
| `viewer_mtls_ca_bundle_pem` | empty | Public PEM CA bundle that the module uploads to S3 when creating a viewer mTLS trust store. Stored in Terraform state. |
| `custom_error_responses` | `[]` | Optional CloudFront custom error responses. |
| `origin_shield` | disabled | Optional CloudFront origin shield configuration. |
| `monitoring` | disabled | Optional CloudFront realtime metrics subscription. |
| `standard_logging_v2` | disabled | Optional CloudFront standard logging v2 log delivery. |
| `allowed_methods` | all methods | Viewer HTTP methods allowed by CloudFront. |
| `price_class` | `PriceClass_100` | CloudFront price class. |
| `http_version` | `http2` | Viewer HTTP version setting. |
| `dns` | disabled | Optional Route53 alias records. |
| `viewer_certificate_arn` | empty | Optional existing ACM viewer certificate ARN in `us-east-1`. Empty creates the managed apex and wildcard certificate. |
| `waf` | `{}` | Optional WebACL creation. Use `waf.allowed_ips` for an IP allowlist and `waf.managed_rules = true` for AWS's Common Rule Set. |
| `waf_advanced` | `{}` | Explicit passthrough for upstream WAF module inputs such as advanced rules, custom responses, token domains, and logging filters. |
| `web_acl_arn` | empty | Existing CloudFront-scoped AWS WAFv2 WebACL ARN to attach. |
| `tags` | `{}` | Tags for AWS resources that support tags. |

## Outputs

| Name | Description |
|------|-------------|
| `distribution_id` | CloudFront distribution ID. |
| `distribution_arn` | CloudFront distribution ARN. |
| `distribution_domain_name` | CloudFront DNS name. |
| `distribution_hosted_zone_id` | Hosted zone ID for Route53 alias records. |
| `aliases` | Configured hostnames. |
| `origin_type` | Effective origin mode. |
| `origin_hostname` | Effective origin hostname. |
| `vpc_origin_id` | CloudFront VPC origin ID when `origin_type = "internal"` or `origin_type = "vpc"`. |
| `web_acl_arn` | Attached WAF WebACL ARN, when configured. |
| `waf` | Created WAF WebACL and IP set details when this module creates a WebACL. |
| `viewer_certificate_arn` | ACM viewer certificate ARN. |
| `viewer_mtls` | Viewer mTLS mode, trust store identifiers, and created trust store audit fields. |
| `origin_client_certificate_arn` | ACM client certificate ARN used for public-origin mTLS. |
| `monitoring_subscription_id` | CloudFront monitoring subscription ID when enabled. |
| `standard_logging_v2` | CloudFront standard logging v2 resource identifiers. |
| `required_dns_records` | CNAME records to create outside Terraform-managed Route53. |
| `route53_records` | Route53 alias records this module manages. |

## Rollout

1. Pick `origin_type = "public"` or `origin_type = "internal"` and confirm the origin security contract.
2. For public origins, configure Ryvn Gateway trust for the origin client certificate CA.
3. Confirm Ryvn serves an origin/server certificate valid for the forwarded Host behavior.
4. Confirm the Route53 public hosted zone for the managed public DNS root exists and is delegated.
5. If viewer mTLS is enabled, create or select the CloudFront trust store and test client certificate issuance.
6. For public origins, import or reference the ACM origin client certificate in `us-east-1`.
7. For VPC origins, create or reference the CloudFront VPC origin and verify security groups/private subnet access.
8. Configure `waf`/`waf_advanced` or select an external CloudFront-scoped WebACL, if WAF is needed.
9. Create the CloudFront distribution.
10. Test before DNS cutover with `curl --connect-to`.
11. Point DNS at CloudFront.
12. Run viewer mTLS, WAF, and direct-origin bypass or VPC-origin access tests.
13. Move WAF rules from count mode to enforcement after review, if you staged custom rules in count mode.

## Local validation

Requires Terraform >= 1.9:

```bash
terraform init -backend=false -reconfigure
terraform fmt -check -recursive
terraform validate
terraform test
```

For production, use a reviewed plan artifact:

```bash
terraform plan -out=tfplan
```

Do not apply directly to production without reviewing the plan and confirming DNS, certificate, WAF, and rollback steps.

## Rollback

- DNS: point the hostname back to the previous target. Lower TTL before cutover where possible.
- CloudFront: reapply the previous distribution config or detach the WebACL.
- VPC origin: disassociate it from the distribution before deleting a managed VPC origin.
- Viewer mTLS: disable `viewer_mtls.enabled` or restore the previous trust store through a reviewed plan.
- WAF: set `waf.enabled = false`, detach `web_acl_arn`, or roll back external WebACL rules.
- Certificates: do not delete imported origin client certificates until CloudFront no longer references them.

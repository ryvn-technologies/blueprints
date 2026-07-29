# CloudFront Edge

Puts AWS CloudFront in front of an environment's public hostnames. CloudFront terminates TLS at the edge, optionally filters traffic with AWS WAF, and forwards each request privately to the environment's internal load balancer through a CloudFront VPC origin. AWS environments only.

## What it creates

- A CloudFront distribution with your hostnames as aliases.
- An ACM certificate in `us-east-1`, DNS-validated in the environment's public Route53 zone.
- A CloudFront VPC origin pointing at the environment's internal load balancer.
- Optionally: an AWS WAF WebACL, a viewer mTLS trust store, cached path behaviors, access log delivery, and real-time metrics.

Some behavior is fixed and has no input:

- Viewers are always redirected to HTTPS.
- The default behavior never caches, and always compresses eligible responses. Opt individual paths in under [Caching](#caching).
- The viewer `Host` header reaches the origin and is part of every cache key, because the origin routes by hostname.
- Every cache behavior targets the environment's origin.

## Hostnames

`hostnames` are the public names CloudFront serves. Leave it empty to serve the environment's public domain apex and its wildcard.

Because the blueprint issues the certificate itself, each hostname must be the environment public domain, its wildcard, or a one-label subdomain of it — `example.com`, `*.example.com`, or `api.example.com`.

Install the blueprint more than once when different hostnames need different WAF rules or cache behavior. Give each installation its own hostnames: CloudFront rejects the same alias on two distributions.

## Pointing DNS at CloudFront

The blueprint does not create DNS records. Add the `externalDnsTargetAnnotation` output to the networking ingress of the service installation that serves the hostname, and external-dns points the record at the distribution.

For hostnames outside a Ryvn-managed zone, read `requiredDnsRecords` and create them in your provider. Apex records need an ALIAS/ANAME-style record if your provider supports one.

Test through the distribution before cutting DNS over:

```bash
curl -sv --connect-to 'api.example.com:443:d123456abcdef8.cloudfront.net:443' https://api.example.com/healthz
```

## Caching

Nothing is cached until you opt a path in; the default behavior uses CloudFront's `Managed-CachingDisabled` policy, which suits API traffic. Two inputs work together:

- `cachePolicies` — a YAML map of named policies: TTLs, cache-key headers, and query strings.
- `orderedCacheBehaviors` — a YAML list of path patterns, each referencing a policy by its map key, evaluated in order before the default behavior.

### cachePolicies

Map keys are the policy's identity, so renaming a behavior's path does not replace its policy, and several behaviors can share one policy. Every policy keys on the URL path and the viewer `Host` header and ignores cookies. CloudFront honors the origin's `Cache-Control` within `min_ttl`/`max_ttl` and falls back to `default_ttl` when the origin sends none.

| Field | Default | Notes |
|------|---------|-------|
| `min_ttl` | `0` | Lower bound on caching, even against origin `Cache-Control`. |
| `default_ttl` | `86400` | Used when the origin sends no caching headers. |
| `max_ttl` | `31536000` | Upper bound on origin-requested TTLs. |
| `enable_accept_encoding_gzip` | `true` | Request and cache gzip. |
| `enable_accept_encoding_brotli` | `true` | Request and cache Brotli. |
| `additional_headers` | `[]` | Extra cache-key headers. `Host` is always included. |
| `query_strings` | `[]` | Query-string allowlist for the cache key. Empty keeps query strings out of the key. |

Each map entry becomes one CloudFront cache policy. AWS allows 20 per account by default ([quota increase][aws-quotas]).

### orderedCacheBehaviors

| Field | Default | Notes |
|------|---------|-------|
| `path_pattern` | required | For example `/_next/static/*`. Unique per installation. |
| `cache_policy_key` | required | A key from `cachePolicies`. |
| `compress` | `true` | [Compress eligible responses at the edge][aws-compression]. |
| `allowed_methods` | `GET, HEAD, OPTIONS` | Viewer methods for this path. |
| `cached_methods` | `GET, HEAD` | Must be a subset of `allowed_methods`. |
| `origin_request_policy_id` / `origin_request_policy_name` | empty | Set at most one. Empty forwards the cache-key values plus CloudFront's standard origin-request values. A policy that drops `Host` breaks origin routing. |
| `response_headers_policy_id` / `response_headers_policy_name` | empty | Set at most one. |

Edge compression on a cached path needs both `compress: true` on the behavior and the encoding enabled in its cache policy. CloudFront normalizes `Accept-Encoding` into the cache key, so gzip, Brotli, and uncompressed responses never share a cache entry.

### Example: Next.js static assets and image optimization

`cachePolicies`:

```yaml
static_assets:
  min_ttl: 0
  default_ttl: 86400
  max_ttl: 31536000
  # both default to true
  enable_accept_encoding_gzip: true
  enable_accept_encoding_brotli: true
image_optimizer:
  default_ttl: 0
  enable_accept_encoding_gzip: true
  enable_accept_encoding_brotli: true
  additional_headers:
    - Accept
  query_strings:
    - url
    - w
    - q
```

`orderedCacheBehaviors`:

```yaml
- path_pattern: "/_next/static/*"
  cache_policy_key: static_assets
  compress: true
- path_pattern: "/_next/image*"
  cache_policy_key: image_optimizer
  compress: true
```

Hashed build output under `/_next/static` varies on nothing, so it keeps the smallest cache key and a long TTL. The image optimizer varies its response by `url`, `w`, and `q` and negotiates the output format from `Accept`, so all four values belong in its cache key. Both paths spell the compression flags out even though all three are `true` by default. Other frameworks differ in path and parameter names; the shape is the same.

### customErrorResponses

A YAML list applied across the distribution. `error_code` (4xx/5xx) is required; `response_code`, `response_page_path`, and `error_caching_min_ttl` are optional.

```yaml
- error_code: 403
  response_code: 403
  response_page_path: "/errors/403.html"
  error_caching_min_ttl: 30
```

## Origin

CloudFront reaches the environment through a CloudFront VPC origin, so origin traffic never crosses the public internet. The blueprint creates one from the environment's internal load balancer; [Advanced](#advanced) covers reusing or retargeting it.

`originReadTimeoutSeconds` sets how long CloudFront waits for an origin response, 1 to 120 seconds. It defaults to 30.

## Viewer mTLS

Set `enableViewerMtls` to make CloudFront validate client certificates against a trust store before forwarding a request. The CA bundle is uploaded to a private, versioned, encrypted S3 bucket in the environment's account and wired into a CloudFront trust store.

| Input | Default | Notes |
|------|---------|-------|
| `viewerMtlsMode` | `required` | `required` rejects callers without a valid certificate; `optional` requests one but still allows callers without it. |
| `viewerMtlsTrustedCaBundle` | from the `trusted-client-ca` variable group | PEM bundle under the `ca.crt` key. Public CA certificates only — no private keys. |
| `viewerMtlsAdvertiseTrustStoreCaNames` | `false` | Advertise accepted CA names during the TLS handshake so callers can present a matching certificate. |
| `viewerMtlsIgnoreCertificateExpiry` | `false` | Accept expired client certificates that still chain to a trusted CA. |

## WAF

By default the blueprint creates a CloudFront-scoped WebACL with four AWS managed rule groups in count mode: matches are recorded but nothing is blocked. Review the counts, then move a group to `block`. Set every group to `disabled` and leave `ipAllowList` empty to skip the WebACL entirely.

| Input | Default | Notes |
|------|---------|-------|
| `wafCommonRuleSetAction` | `count` | Common web app attacks such as XSS, path traversal, and oversized requests. |
| `wafKnownBadInputsAction` | `count` | Request patterns linked to known exploits. |
| `wafAmazonIpReputationAction` | `count` | Sources AWS links to bots, DDoS, or scanning. |
| `wafAnonymousIpAction` | `count` | VPNs, proxies, Tor, and hosting providers that hide the caller. |
| `ipAllowList` | `[]` | CIDR blocks allowed to reach CloudFront. Empty allows all sources. IPv4 and IPv6 may be mixed. |

Setting `ipAllowList` flips the WebACL's default action to block and appends the allow rules after the managed rules, so:

- allowlisted IP, clean request → allowed
- allowlisted IP, request a managed rule blocks → blocked
- any other IP → `403`

To attach a WebACL you manage elsewhere, set `webAclArn` to a CloudFront-scoped (`us-east-1`, `global/webacl/…`) ARN. It replaces the rule inputs above, since CloudFront accepts one WebACL per distribution.

## Logging

Logs are delivered to S3 buckets you already own; the blueprint does not create them.

| Input | Default | Notes |
|------|---------|-------|
| `enableCloudFrontLogging` / `cloudFrontLogBucketArn` | off | CloudFront standard access logs to an existing S3 bucket. |
| `enableWafLogging` / `wafLogBucketArn` | off | WAF request logs to an existing same-account S3 bucket. AWS requires the bucket name to start with `aws-waf-logs-` ([details][aws-waf-logging]). |

## Advanced

| Input | Default | Notes |
|------|---------|-------|
| `existingVpcOriginId` | empty | Reuse a VPC origin instead of creating one. Pair it with another installation's `vpcOriginId` output to share one VPC origin across distributions. |
| `vpcOriginEndpointLookupTags` | empty | YAML map of AWS tags selecting the load balancer behind the VPC origin. Empty uses the environment's internal load balancer. Changing the endpoint replaces the VPC origin. |
| `vpcOriginName` | generated | Name for the created VPC origin. A short endpoint fingerprint suffix is always appended. |
| `priceClass` | `PriceClass_100` | Edge locations: `PriceClass_100` (North America and Europe), `PriceClass_200`, or `PriceClass_All`. |
| `enableMonitoring` | `false` | CloudFront real-time metrics. |
| `waitForDeployment` | `false` | Wait for CloudFront to finish deploying before the installation completes. |
| `retainOnDelete` | `false` | Disable the distribution instead of deleting it when the installation is removed. |

## Outputs

| Output | Description |
|------|-------------|
| `distributionId` | CloudFront distribution ID. |
| `distributionArn` | CloudFront distribution ARN. |
| `distributionDomainName` | Distribution DNS name — the DNS target for your hostnames. |
| `vpcOriginId` | VPC origin ID. Pass it to another installation's `existingVpcOriginId` to share one VPC origin. |
| `webAclArn` | WebACL attached to the distribution, when one is configured. |
| `externalDnsTargetAnnotation` | Annotation to add to a service installation's networking ingress so DNS targets CloudFront. |
| `requiredDnsRecords` | Records to create yourself when Ryvn is not managing the zone. |

## AWS permissions

The environment's Terraform executor needs these actions:

```text
acm:AddTagsToCertificate
acm:DeleteCertificate
acm:DescribeCertificate
acm:ListTagsForCertificate
acm:RemoveTagsFromCertificate
acm:RequestCertificate
cloudfront:AllowVendedLogDeliveryForResource
cloudfront:AssociateDistributionWebACL
cloudfront:CreateCachePolicy
cloudfront:CreateConnectionGroup
cloudfront:CreateDistribution
cloudfront:CreateMonitoringSubscription
cloudfront:CreateTrustStore
cloudfront:CreateVpcOrigin
cloudfront:DeleteCachePolicy
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
cloudfront:UpdateCachePolicy
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

[aws-compression]: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/ServingCompressedFiles.html
[aws-quotas]: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cloudfront-limits.html
[aws-waf-logging]: https://docs.aws.amazon.com/waf/latest/developerguide/logging-s3.html

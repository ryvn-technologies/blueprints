# Cloudflare Edge

Put Cloudflare in front of your Ryvn environment. Public traffic enters through Cloudflare — your domain, your WAF, Cloudflare's global network — and Cloudflare forwards it securely to Ryvn's public edge over mTLS.

## What this does

For each hostname you configure, this module:

1. Creates a proxied Cloudflare DNS record pointing to your Ryvn environment's public entry point.
2. Enforces strict origin TLS so Cloudflare always validates the origin's certificate.
3. Enables per-hostname Authenticated Origin Pulls (AOP) — Cloudflare presents a client certificate to Ryvn's public edge on every request, and the edge rejects any request that doesn't carry it.
4. Optionally applies WAF rules (Cloudflare Managed Ruleset, OWASP Core Ruleset, custom rules, rate limits, IP allow/block lists) scoped to your proxied hostnames.

The mTLS between Cloudflare and Ryvn is always on.

## Before you start

### Ryvn environment trusted CA

Ryvn's public edge needs to trust the CA that signed the AOP client certificate you uploaded to Cloudflare. Configure the public CA bundle on your Ryvn environment via a variable group (`trusted_ca`) — this is done separately from this module.

### Client certificate in Cloudflare

Upload or create the client certificate in Cloudflare and copy its ID. The module references it by ID only — the private key never leaves Cloudflare and never touches Terraform state.

### Cloudflare API token

Scope the token to the single Cloudflare zone this module manages — zone-level permissions only.

Use the helper to open Cloudflare's token creation form with the correct permissions and zone scope pre-filled:

```bash
scripts/cloudflare-token-url \
  --account-id <cloudflare-account-id> \
  --zone-id <cloudflare-zone-id> \
  --open
```

Use `--copy` instead of `--open` to put the URL on your clipboard. Review and confirm the token in Cloudflare, then store the secret in Ryvn and verify it works:

```bash
export CLOUDFLARE_API_TOKEN="<token>"
scripts/cloudflare-verify-token --zone-id <cloudflare-zone-id>
```

Before saving the token, check that every permission is under **Zone** (not Account) and that **Zone Resources** is set to this specific zone.

Required zone permissions:

| Permission | Required for |
|------------|-------------|
| `DNS Write` | Proxied DNS records |
| `Config Rules Edit` | Hostname-scoped strict origin TLS configuration rule |
| `SSL and Certificates Write` | Per-hostname Authenticated Origin Pulls |
| `Zone WAF Write` | WAF rulesets (only when `waf.enabled = true`) |
| `Zone Read` | Zone reads used by the Cloudflare provider |
| `Origin Write` | Origin routing ruleset (only when `origin_port != 443` or `origin_sni` is set) |

## Minimal configuration

```yaml
cloudflare_api_token: "<from Ryvn secret or variable group>"
zone_id: "0123456789abcdef0123456789abcdef"

hostnames:
  - "api.example.com"

origin_hostname: "origin.staging.nextcorp.ryvn.run"
authenticated_origin_pulls_certificate_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

waf:
  enabled: false
```

That's it. All other settings have safe defaults.

## With WAF

Start managed rules in log mode so you can verify there are no false positives before switching to block:

```yaml
cloudflare_api_token: "<from Ryvn secret or variable group>"
zone_id: "0123456789abcdef0123456789abcdef"
ruleset_name_prefix: "acme-prod"

hostnames:
  - "api.acme.com"

origin_hostname: "origin.prod.acme.ryvn.run"
authenticated_origin_pulls_certificate_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

waf:
  enabled: true
  managed_rules:
    cloudflare_managed:
      enabled: true
    owasp:
      enabled: true
      action: "log"
      paranoia_level: 1
      score_threshold: 60
```

## Partial/CNAME setup (Route53 or external DNS)

If Cloudflare is not your authoritative DNS (common when Route53 is), the setup is the same — this module still creates the Cloudflare-side proxied record, enables AOP and hostname-scoped strict SSL, and applies WAF. The only difference is you also need to create a CNAME in Route53 pointing your hostname to Cloudflare's CNAME target.

Run `terraform output required_dns_records` after apply to get the exact CNAME value for each hostname. Lower the TTL on the Route53 record ahead of time so you can roll back quickly if needed.

Pre-stage the Cloudflare configuration first, verify AOP and WAF in log mode, then flip the CNAME. Rollback is a CNAME flip back to the Ryvn origin address.

## Inputs

**Required:**

| Name | Description |
|------|-------------|
| `cloudflare_api_token` | Zone-scoped Cloudflare API token. Store in Ryvn as a secret. |
| `zone_id` | Your Cloudflare zone ID (32-character hex, on the zone overview page). |
| `hostnames` | One or more exact hostnames to proxy, e.g. `api.example.com`. |
| `origin_hostname` | Your Ryvn environment's public origin address — Cloudflare forwards proxied traffic here. |
| `authenticated_origin_pulls_certificate_id` | ID of an existing Cloudflare client certificate to use for AOP. |

**Optional:**

| Name | Default | Description |
|------|---------|-------------|
| `origin_port` | `443` | Port Cloudflare connects to on your origin. |
| `origin_sni` | `""` | SNI Cloudflare uses toward your origin. Leave blank to use the request hostname. |
| `ruleset_name_prefix` | `"ryvn"` | Prefix for Cloudflare ruleset names — useful to namespace per environment. |
| `waf` | `{}` | WAF configuration. Disabled by default. |

## Wildcard hostnames

This module currently accepts exact hostnames only because it uses per-hostname AOP. We tested per-hostname AOP with a wildcard hostname, but Cloudflare did not present the client certificate to the origin. Future wildcard support should use an explicit zone-level AOP mode: Cloudflare supports proxied wildcard DNS records, and zone-level AOP authenticates all proxied traffic in the zone with an uploaded client certificate. That mode also needs wildcard-aware WAF/origin rules, for example `http.host wildcard "*.example.com"`, plus edge and origin TLS coverage for the wildcard names.

References: [wildcard DNS records](https://developers.cloudflare.com/dns/manage-dns-records/reference/wildcard-dns-records/), [zone-level AOP](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/zone-level/), [per-hostname AOP](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/per-hostname/), [wildcard rule operators](https://developers.cloudflare.com/ruleset-engine/rules-language/operators/#wildcard-matching).

## WAF

`waf.enabled` is the on/off switch. When enabled, at least one rule must be active.

All WAF rules are automatically scoped to the `hostnames` you configured. `waf.scope_expression` narrows the scope further (ANDed with the hostname scope) — it cannot broaden it beyond your hostnames.

### Managed rules

| Field | Default | Description |
|-------|---------|-------------|
| `managed_rules.cloudflare_managed.enabled` | `false` | [Cloudflare Managed Ruleset](https://developers.cloudflare.com/waf/managed-rules/reference/cloudflare-managed-ruleset/) — Pro plan and above. |
| `managed_rules.owasp.enabled` | `false` | [OWASP Core Ruleset](https://developers.cloudflare.com/waf/managed-rules/reference/owasp-core-ruleset/) — Pro plan and above. |
| `managed_rules.owasp.action` | `"log"` | Action when the OWASP anomaly score is exceeded: `log`, `block`, `challenge`, `js_challenge`, `managed_challenge`. |
| `managed_rules.owasp.paranoia_level` | `1` | OWASP paranoia level 1–4. Higher levels apply stricter rule categories. |
| `managed_rules.owasp.score_threshold` | `60` | Anomaly score that triggers the action. |
| `managed_rules.cloudflare_free.enabled` | `false` | [Cloudflare Free Managed Ruleset](https://developers.cloudflare.com/waf/managed-rules/) — high-impact, widely exploited vulnerabilities. Available on all plans. |
| `managed_rules.sensitive_data_detection.enabled` | `false` | [Sensitive Data Detection](https://developers.cloudflare.com/waf/managed-rules/reference/sensitive-data-detection/) in the response phase. Enterprise only; log-only. |

To suppress a specific managed rule that produces false positives, use `managed_rule_exceptions`:

```yaml
waf:
  enabled: true
  managed_rules:
    cloudflare_managed:
      enabled: true
  managed_rule_exceptions:
    - ref: "skip_false_positive"
      rules:
        cloudflare_managed:
          - "rule-id-here"
```

### IP allow and block lists

```yaml
waf:
  enabled: true
  ip_allowlist:
    - "203.0.113.0/24"
    - "198.51.100.7"
  ip_blocklist:
    - "192.0.2.10"
```

`ip_allowlist` is default-deny: sources outside the list are blocked. Both lists accept IPv4/IPv6 addresses and CIDR ranges and evaluate before custom rules.

### Custom rules and rate limits

```yaml
waf:
  enabled: true
  custom_rules:
    - ref: "skip_healthcheck"
      description: "Skip WAF for health check path"
      action: "skip"
      expression: 'http.request.uri.path eq "/health"'
  rate_limit_rules:
    - ref: "api_login_rate_limit"
      description: "Throttle login endpoint"
      action: "managed_challenge"
      expression: 'http.request.uri.path eq "/login"'
      characteristics:
        - "ip.src"
      period: 60
      requests_per_period: 20
```

`ref` values must be unique within each of `custom_rules`, `rate_limit_rules`, and `managed_rule_exceptions`.

### Advanced rules

For anything the typed inputs above don't cover — custom `action_parameters`, advanced `skip` targets, executing additional managed rulesets — pass native Cloudflare ruleset rule objects through `advanced`, keyed by phase:

```yaml
waf:
  enabled: true
  advanced:
    custom:
      - ref: "block_legacy_with_custom_response"
        action: "block"
        expression: 'http.request.uri.path eq "/legacy"'
        action_parameters:
          response:
            status_code: 403
            content: "Access denied"
            content_type: "text/plain"
```

Advanced rules are appended after typed rules in their phase. Their expressions are still ANDed with the hostname scope. The module passes them through to the Cloudflare provider as-is — Cloudflare validates the shape at plan time. See the [`cloudflare_ruleset` rules reference](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/ruleset).

## Outputs

| Name | Description |
|------|-------------|
| `dns_records` | Proxied Cloudflare DNS records managed by this module, keyed by hostname. |
| `required_dns_records` | CNAME records to create in your authoritative DNS for partial/CNAME setup. |
| `hostnames` | Effective origin, SNI, port, client certificate, and WAF scope per hostname. |
| `authenticated_origin_pulls` | AOP state and certificate IDs per hostname. |
| `ruleset_ids` | IDs of Cloudflare rulesets this module manages. |
| `cloudflare_ip_ranges` | Cloudflare IPv4 and IPv6 ranges for your origin-side firewall allowlist. |

## Zone-level effects

Cloudflare rulesets are zone resources even when every rule expression is hostname-scoped:

- **Strict SSL** is enforced through a Configuration Rule in the `http_config_settings` phase, scoped to the configured hostnames. The module does not change the zone-wide SSL mode.
- **One entry-point ruleset per phase per zone** — run at most one cloudflare-edge installation per Cloudflare zone.

## Local validation

Requires Terraform >= 1.9. Run locally without a backend:

```bash
terraform init -backend=false -reconfigure
terraform fmt -check -recursive
terraform validate
terraform test
```

#!/bin/bash
# Egress probe matrix. Prints "<id> expect=<...> got=<verdict> <detail>".
# Runs inside a pod (nicolaka/netshoot) or on an Ubuntu VM. Needs curl; nc/dig optional.
# Usage: probe.sh <class>   class = cluster | vm
#
# Verdicts (correlate with Azure Firewall AZFWApplicationRule/AZFWNetworkRule logs):
#   ALLOWED           any HTTP status from the origin (even 4xx/5xx) or a completed TCP handshake
#   BLOCKED-app       470 = Azure Firewall HTTP deny page (application-rule deny on plaintext HTTP)
#   BLOCKED-reset     TLS/connection reset before the origin answered (application-rule deny on TLS)
#   BLOCKED-timeout   no SYN/ACK (network-rule deny / unmatched non-web)
#   INCONCLUSIVE-dns  curl(6) name resolution failed: says nothing about the firewall
# Hostname negatives use --resolve to pin the SNI/Host to a controlled origin IP that the
# same class is allowed to reach under a different name, so DNS cannot mask the result and
# an origin canary (the allowed name on the same IP) proves the path itself is open.
class="${1:-cluster}"
T=8
c() { curl -sS -o /dev/null -m "$T" --retry 0 -w '%{http_code} exit=%{exitcode}' "$@" 2>&1 | tail -c 200; }
# Raw bytes to a port. Azure Firewall's transparent HTTP proxy answers malformed plaintext
# on port 80 itself with "HTTP/1.1 400 Bad Request" + "Content-Type: text/plain; charset=utf-8"
# and no Server/Date header; a real origin answer carries Server/Date (or any other header).
raw() { # ip port payload
  local r; r="$(printf '%b' "$3" | nc -w 5 "$1" "$2" 2>&1 | head -c 400)"
  if [ -z "$r" ]; then echo "no-reply exit=nc"
  elif printf '%s' "$r" | grep -qi '^\(Server\|Date\|Via\|X-\)'; then
    echo "origin-reply=$(printf '%s' "$r" | head -1 | tr -d '\r') 200"
  else echo "fw-proxy-reply=$(printf '%s' "$r" | head -1 | tr -d '\r') exit=fw"; fi
}
tcp() { # host port
  if command -v dig >/dev/null 2>&1 && [ "$2" = 53 ]; then
    dig +tcp +time=4 +tries=1 "@$1" example.com A 2>&1 | grep -q 'status:' && echo tcp-ok || echo tcp-fail
  else
    curl -sS -m 5 -v "telnet://$1:$2" </dev/null 2>&1 | grep -q '^\* Connected' && echo tcp-ok || echo tcp-fail
  fi
}
# UDP datagram probe. `curl --http3` is not built into the probe image, so QUIC closure is
# exercised as raw UDP/443 datagrams: any reply => ALLOWED, silence => BLOCKED-timeout.
# The verdict is only meaningful together with the matching AZFWNetworkRule Deny row.
udp() { # host port
  local r; r="$(printf 'QUIC-PROBE\r\n' | nc -u -w 4 "$1" "$2" 2>&1 | head -c 200)"
  if [ -n "$r" ]; then echo "udp-reply 200"; else echo "udp-no-reply exit=28"; fi
}
resolve4() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
row() { # id expect cmd...
  local id="$1" exp="$2"; shift 2
  local out; out="$("$@")"
  local v
  case "$out" in
    470*) v=BLOCKED-app ;;
    [1-5][0-9][0-9]*|origin-reply=*|tcp-ok) v=ALLOWED ;;
    *exit=fw*) v=BLOCKED-app ;;
    *exit=6*) v=INCONCLUSIVE-dns ;;
    *exit=28*) v=BLOCKED-timeout ;;
    *exit=35*|*exit=52*|*exit=56*|*exit=7*) v=BLOCKED-reset ;;
    *) v=BLOCKED ;;
  esac
  printf '%-34s expect=%-8s got=%-16s %s\n' "$id" "$exp" "$v" "$(echo "$out" | tr '\n' ' ' | cut -c1-110)"
}

if [ "$class" = cluster ]; then
  # controlled origin: an IP the cluster may reach under *.gstatic.com
  O="$(resolve4 fonts.gstatic.com)"; echo "controlled-origin fonts.gstatic.com=${O}"
  # example.com (Cloudflare) answers plaintext/garbage on :443 and :80 with an HTTP 400 that
  # carries Server/Date headers, so it is the canary origin for the non-TLS-on-443 cases:
  # a 400 with those headers means the firewall let the bytes reach the origin.
  C="$(resolve4 example.com)"; echo "plaintext-capable-origin example.com=${C}"
  row https-exact-allowed        ALLOWED  c https://api.github.com/
  row https-wildcard-child       ALLOWED  c https://fonts.gstatic.com/
  # NOTE: the URL path in ssl.gstatic.com/gb/... adds no DNS labels; ssl.gstatic.com is a
  # one-label child like fonts.gstatic.com. Real multi-label descendants are exercised in the
  # controlled-origin section below (a.b.<origin>.sslip.io).
  row https-wildcard-child-2     ALLOWED  c https://ssl.gstatic.com/gb/images/
  row origin-canary-allowed-name ALLOWED  c -k --resolve "fonts.gstatic.com:443:$O" https://fonts.gstatic.com/
  row https-wildcard-apex        BLOCKED  c -k --resolve "gstatic.com:443:$O" https://gstatic.com/
  row https-lookalike-suffix     BLOCKED  c -k --resolve "notgstatic.com:443:$O" https://notgstatic.com/
  row https-lookalike-sibling    BLOCKED  c -k --resolve "gstatic.com.example.org:443:$O" https://gstatic.com.example.org/
  row https-unmatched-same-ip    BLOCKED  c -k --resolve "example.org:443:$O" https://example.org/
  row https-unmatched            BLOCKED  c https://example.org/
  row http-allowed               ALLOWED  c http://neverssl.com/
  row http-of-https-only-name    BLOCKED  c http://api.github.com/
  row https-of-http-only-name    BLOCKED  c https://neverssl.com/
  row https-raw-ip-no-sni        BLOCKED  c -k "https://$O/"
  row http-raw-ip                BLOCKED  c "http://$C/"
  row https-alt-port-8443        BLOCKED  c https://api.github.com:8443/
  row http-alt-port-8080         BLOCKED  c http://neverssl.com:8080/
  row plaintext-h1-allowed-host-443 BLOCKED c -H 'Host: api.github.com' "http://$C:443/"
  row plaintext-h1-disallowed-host-443 BLOCKED c -H 'Host: example.org' "http://$C:443/"
  row plaintext-h1-no-host-443   BLOCKED  raw "$C" 443 'GET / HTTP/1.0\r\n\r\n'
  row malformed-nonweb-443       BLOCKED  raw "$C" 443 'HELLO FIREWALL\r\n\r\n'
  row malformed-nonweb-80        BLOCKED  raw "$C" 80 'HELLO FIREWALL\r\n\r\n'
  row tls-on-80                  BLOCKED  c https://neverssl.com:80/
  row tcp-pinhole-9.9.9.9:53     ALLOWED  tcp 9.9.9.9 53
  row tcp-non-pinhole-1.1.1.1:53 BLOCKED  tcp 1.1.1.1 53
  row ssh-github-22              BLOCKED  tcp github.com 22
  row quic-udp443                BLOCKED  udp www.google.com 443
  row icmp-8.8.8.8               BLOCKED  sh -c 'ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 && echo 200 || echo icmp-fail'
  row aks-baseline-mcr           ALLOWED  c https://mcr.microsoft.com/v2/
  row aks-baseline-mgmt          ALLOWED  c https://management.azure.com/
  row azure-broad-not-allowed    BLOCKED  c https://portal.azure.com/
  row imds-metadata              ALLOWED  c -H Metadata:true 'http://169.254.169.254/metadata/instance?api-version=2021-02-01'
else
  O="$(resolve4 example.com)"; echo "controlled-origin example.com=${O} (Cloudflare; answers plaintext on :443 with 400)"
  row vm-https-exact-allowed     ALLOWED  c https://example.com/
  row vm-origin-canary           ALLOWED  c -k --resolve "example.com:443:$O" https://example.com/
  row vm-https-www-not-apex      BLOCKED  c -k --resolve "www.example.com:443:$O" https://www.example.com/
  row vm-lookalike-suffix        BLOCKED  c -k --resolve "notexample.com:443:$O" https://notexample.com/
  row vm-unmatched-same-ip       BLOCKED  c -k --resolve "example.org:443:$O" https://example.org/
  row vm-http-not-allowed        BLOCKED  c http://example.com/
  row vm-cluster-domain-isolated BLOCKED  c https://api.github.com/
  row vm-cluster-baseline-isol   BLOCKED  c https://mcr.microsoft.com/v2/
  row vm-raw-ip                  BLOCKED  c -k "https://$O/"
  row vm-plaintext-h1-host-443   BLOCKED  c -H 'Host: example.com' "http://$O:443/"
  row vm-plaintext-h1-no-host-443 BLOCKED raw "$O" 443 'GET / HTTP/1.0\r\n\r\n'
  row vm-malformed-nonweb-443    BLOCKED  raw "$O" 443 'HELLO FIREWALL\r\n\r\n'
  row vm-malformed-nonweb-80     BLOCKED  raw "$O" 80 'HELLO FIREWALL\r\n\r\n'
  row vm-tcp-pinhole-not-shared  BLOCKED  tcp 9.9.9.9 53
  row vm-ssh-22                  BLOCKED  tcp github.com 22
  row vm-icmp                    BLOCKED  sh -c 'ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 && echo 200 || echo icmp-fail'
  row vm-imds                    ALLOWED  c -H Metadata:true 'http://169.254.169.254/metadata/instance?api-version=2021-02-01'
fi

# ---------------------------------------------------------------------------
# Controlled instrumented origin (origin-server.py on a VM with public IP $ORIGIN_IP,
# reachable from the probe only through the firewall). Names are provider-resolvable
# sslip.io names: D=<a-b-c-d>.sslip.io resolves to a.b.c.d at any label depth, so the
# firewall's own DNS proxy resolves apex/child/deep/lookalike without client --resolve.
# Expected policy: cluster https allows "*.$D" (wildcard); vm https allows "origin.$D" (exact).
# Every row here must be correlated with the origin log: a firewall deny leaves NO row on the
# origin; "ORIGIN-*" in the client output or an origin log row means bytes escaped.
# ---------------------------------------------------------------------------
if [ -n "${ORIGIN_IP:-}" ]; then
  D="$(echo "$ORIGIN_IP" | tr . -).sslip.io"
  # sibling wildcard base that resolves to a *different* (unowned) IP
  SIB="$(echo "$ORIGIN_IP" | awk -F. '{printf "%s-%s-%s-%d", $1,$2,$3,($4+1)%256}').sslip.io"
  echo "controlled-origin ${ORIGIN_IP} D=${D} resolved=$(resolve4 "a.b.$D") sibling=${SIB} resolved=$(resolve4 "a.$SIB")"
  o() { curl -sS -k -m "$T" --retry 0 -w ' %{http_code} exit=%{exitcode}' "$@" 2>&1 | tr -d '\r' | tr '\n' ' ' | tail -c 200; }
  orow() { # id expect curl-args...  (verdict also inspects the body for ORIGIN- banners)
    local id="$1" exp="$2"; shift 2
    local out v; out="$(o "$@")"
    case "$out" in
      *ORIGIN-*) v=ALLOWED-origin-bytes ;;
      *' 470 '*) v=BLOCKED-app ;;
      *exit=6*) v=INCONCLUSIVE-dns ;;
      *exit=28*) v=BLOCKED-timeout ;;
      *exit=35*|*exit=52*|*exit=56*|*exit=7*) v=BLOCKED-reset ;;
      *' 200 '*|*' 400 '*) v=ALLOWED ;;
      *) v=INCONCLUSIVE ;;
    esac
    printf '%-34s expect=%-8s got=%-20s %s\n' "$id" "$exp" "$v" "$(echo "$out" | cut -c1-110)"
  }
  if [ "$class" = cluster ]; then
    orow ctl-wildcard-child          ALLOWED "https://a.$D/"
    orow ctl-wildcard-deep-2         ALLOWED "https://a.b.$D/"
    orow ctl-wildcard-deep-3         ALLOWED "https://a.b.c.$D/"
    orow ctl-wildcard-apex           BLOCKED "https://$D/"
    orow ctl-sibling-base-resolvable BLOCKED "https://a.$SIB/"
    orow ctl-lookalike-prefix        BLOCKED --resolve "xa.x$D:443:$ORIGIN_IP" "https://xa.x$D/"
    orow ctl-lookalike-suffix        BLOCKED --resolve "a.$D.example.org:443:$ORIGIN_IP" "https://a.$D.example.org/"
    orow ctl-unmatched-same-ip       BLOCKED --resolve "example.org:443:$ORIGIN_IP" "https://example.org/"
    orow ctl-http-of-https-only-child BLOCKED "http://a.$D/"
    orow ctl-plaintext-h1-allowed-host-443 BLOCKED -H "Host: a.b.$D" "http://$ORIGIN_IP:443/"
    orow ctl-plaintext-h1-no-host-443 BLOCKED --http1.0 -H 'Host:' "http://$ORIGIN_IP:443/"
    orow ctl-no-sni-raw-ip-443       BLOCKED "https://$ORIGIN_IP/"
    orow ctl-raw-ip-80               BLOCKED "http://$ORIGIN_IP/"
  else
    orow vm-ctl-exact                ALLOWED "https://origin.$D/"
    orow vm-ctl-child-of-exact       BLOCKED "https://a.origin.$D/"
    orow vm-ctl-apex                 BLOCKED "https://$D/"
    orow vm-ctl-sibling-resolvable   BLOCKED "https://origin.$SIB/"
    orow vm-ctl-http-of-exact        BLOCKED "http://origin.$D/"
    orow vm-ctl-plaintext-h1-allowed-host-443 BLOCKED -H "Host: origin.$D" "http://$ORIGIN_IP:443/"
    orow vm-ctl-no-sni-raw-ip-443    BLOCKED "https://$ORIGIN_IP/"
  fi
  # malformed / non-web bytes: origin answers ORIGIN-PLAINTEXT to anything; the firewall's
  # own proxy answers a bare "HTTP/1.1 400 Bad Request" with no Server header.
  for port in 443 80; do
    r="$(printf 'HELLO FIREWALL\r\n\r\n' | nc -w 5 "$ORIGIN_IP" "$port" 2>&1 | tr -d '\r' | tr '\n' ' ' | head -c 200)"
    case "$r" in
      *ORIGIN-*) v=ALLOWED-origin-bytes ;;
      "") v=INCONCLUSIVE-empty-reply ;;   # correlate with origin log: no row => denied before origin
      *"400 Bad Request"*) v=BLOCKED-app ;;
      *) v=INCONCLUSIVE ;;
    esac
    printf '%-34s expect=%-8s got=%-20s %s\n' "ctl-malformed-nonweb-$port" BLOCKED "$v" "$(echo "$r" | cut -c1-110)"
  done
fi

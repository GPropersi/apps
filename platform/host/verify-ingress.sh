#!/usr/bin/env bash
# verify-ingress.sh: client-side, fail-closed check that the public wildcard sits behind Cloudflare Access.
#
# It requests a random, unused name under the domain the way a stranger would and passes only when the Access login
# wall is positively seen (access_gate_check rc 0). Anything else fails: open (1), unreachable (2) and unconfirmed (3)
# each print a distinct message. The check is the shared one, vendored below byte-identically from the stronghold's
# .claude/scripts/lib/access-gate.sh; this file's path must be registered in `access_gate_copies` there (a post-merge
# stronghold follow-up: register `apps/platform/host/verify-ingress.sh` in `access_gate_copies`).
#
# This script runs only on the machine you are on. It makes no ssh or sudo call and does not embed as a payload.
# The on-host checks (container health, routing, /_jobs denial) stay in `install-ingress.sh verify`; run them with
# `make host-ingress HOST=<alias> ARGS="verify"` (the command is printed when --host is given).
#
# Usage: verify-ingress.sh [--host ALIAS] [--domain DOMAIN] [--expect-open HOST]... [--probe-jobs APP-HOST]
#   --host         only labels the output and selects the on-host command that is printed; no connection is made
#   --domain       the public domain; else PLATFORM_DOMAIN from the environment. Never defaulted: with none, exit 2
#                  and no network call
#   --expect-open  a hostname that is deliberately public: it passes only on rc 1 (open, no Access challenge); the
#                  random name must still be gated. Repeatable
#   --probe-jobs   manual check only, never automated: prints the commands to try against an app host. The gate
#                  blocks unauthenticated requests before Traefik, so the automated /_jobs probes are in
#                  `install-ingress.sh verify --live`
#
# Exit: 0 every check passed | 1 a check failed (open, unreachable or unconfirmed) | 2 usage error or no domain
set -uo pipefail

export LC_ALL=C

# >>> access-gate (canonical: .claude/scripts/lib/access-gate.sh) >>>
# access_gate_check <hostname>: returns 0 gated, 1 open (200, no challenge),
# 2 unreachable, 3 unconfirmed (anything else, incl. empty hostname).
# Sets ACCESS_GATE_CODE to the observed HTTP status (empty when unreachable).
access_gate_check() {
  ACCESS_GATE_CODE=""
  local host="${1:-}" headers line lower val rest auth
  if [ -z "$host" ]; then
    return 3
  fi
  if ! headers="$(curl -sS -I --max-time 10 "https://${host}/" 2>/dev/null)"; then
    return 2
  fi
  ACCESS_GATE_CODE="$(printf '%s' "$headers" | awk 'toupper($1) ~ /^HTTP/ {c=$2; sub(/\r$/, "", c)} END{print c}')"
  while IFS= read -r line || [ -n "$line" ]; do
    lower="${line,,}"
    case "$lower" in
      cf-access*|x-cf-access*)
        return 0
        ;;
      location:*)
        val="${line#*:}"
        val="${val#"${val%%[![:space:]]*}"}"
        case "$val" in
          *://*) ;;
          *) continue ;;
        esac
        rest="${val#*://}"
        auth="${rest%%[/?#$'\r']*}"
        if [[ "$auth" =~ ^(.*):[0-9]+$ ]]; then
          auth="${BASH_REMATCH[1]}"
        fi
        auth="${auth,,}"
        if [[ "$auth" =~ ^[a-z0-9.-]+$ ]]; then
          case "$auth" in
            cloudflareaccess.com|*.cloudflareaccess.com) return 0 ;;
          esac
        fi
        ;;
    esac
  done <<< "$headers"
  if [ "$ACCESS_GATE_CODE" = "200" ]; then
    return 1
  fi
  return 3
}
# <<< access-gate <<<

readonly DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'

FAILURES=0

err() { printf 'verify-ingress: %s\n' "$1" >&2; }
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

valid_host() { [ "${#1}" -le 253 ] && [[ "$1" =~ $DOMAIN_RE ]]; }

# assert_gated <hostname>: only rc 0 passes; rc 1, 2 and 3 each fail with their own message.
assert_gated() {
  local h="$1" rc=0
  access_gate_check "$h" || rc=$?
  case "$rc" in
    0) pass "$h is behind Cloudflare Access (an unauthenticated request is challenged)" ;;
    1) fail "$h answered 200 WITHOUT an Access challenge: it is exposed unauthenticated. Repair the wildcard Access application and its Allow policy" ;;
    2) fail "could not reach https://$h: the wildcard DNS record, tunnel route or Access application is not live yet" ;;
    *) fail "could not confirm Cloudflare Access on $h (unexpected response: HTTP ${ACCESS_GATE_CODE:-?}). Check the Access application and policy in the Zero Trust dashboard" ;;
  esac
}

# assert_open <hostname>: a deliberate public exception; only rc 1 passes.
assert_open() {
  local h="$1" rc=0
  access_gate_check "$h" || rc=$?
  case "$rc" in
    1) pass "$h is open as expected (--expect-open: answered 200 with no Access challenge)" ;;
    0) fail "$h is behind Cloudflare Access but --expect-open said it should be public" ;;
    2) fail "could not reach https://$h (named by --expect-open)" ;;
    *) fail "could not classify $h (named by --expect-open; unexpected response: HTTP ${ACCESS_GATE_CODE:-?})" ;;
  esac
}

main() {
  local host="" domain="${PLATFORM_DOMAIN:-}" probe_jobs="" h label
  local -a expect_open=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) [ $# -ge 2 ] || { err "missing value for --host"; return 2; }; host="$2"; shift 2 ;;
      --domain) [ $# -ge 2 ] || { err "missing value for --domain"; return 2; }; domain="$2"; shift 2 ;;
      --expect-open) [ $# -ge 2 ] || { err "missing value for --expect-open"; return 2; }; expect_open+=("$2"); shift 2 ;;
      --probe-jobs) [ $# -ge 2 ] || { err "missing value for --probe-jobs"; return 2; }; probe_jobs="$2"; shift 2 ;;
      -h | --help) sed -n '2,/^set -/{/^set -/!p;}' "${BASH_SOURCE[0]}"; return 0 ;;
      *) err "unknown argument: $1"; return 2 ;;
    esac
  done
  if [ -z "$domain" ]; then
    err "no domain: pass --domain DOMAIN or set PLATFORM_DOMAIN in the environment (it is never defaulted)"
    return 2
  fi
  valid_host "$domain" || { err "the domain is not a lowercase DNS name (labels of a-z, 0-9, hyphen; at least two labels)"; return 2; }
  for h in ${expect_open[@]+"${expect_open[@]}"}; do
    valid_host "$h" || { err "--expect-open value is not a lowercase DNS name: $h"; return 2; }
  done
  if [ -n "$probe_jobs" ]; then
    valid_host "$probe_jobs" || { err "--probe-jobs value is not a lowercase DNS name: $probe_jobs"; return 2; }
  fi
  command -v curl >/dev/null 2>&1 || { err "curl is required"; return 2; }

  label="${host:+ (host alias $host)}"
  printf 'verify-ingress: public check of the wildcard under %s%s\n' "$domain" "$label"

  assert_gated "ingress-verify-${RANDOM}${RANDOM}.${domain}"
  for h in ${expect_open[@]+"${expect_open[@]}"}; do assert_open "$h"; done

  if [ -n "$probe_jobs" ]; then
    printf 'MANUAL (not run): signed in through the Access login in a browser, request https://%s/_jobs and a case variant such as /_JOBS: both must answer 503. Unauthenticated requests never reach Traefik, so the automated /_jobs probes are in "verify --live" on the host.\n' "$probe_jobs"
  fi
  if [ -n "$host" ]; then
    printf 'On-host checks (not run here, no ssh is made): make host-ingress HOST=%s ARGS="verify"\n' "$host"
  fi

  if [ "$FAILURES" -gt 0 ]; then
    printf 'verify-ingress: %d check(s) failed\n' "$FAILURES"
    return 1
  fi
  echo "verify-ingress: OK"
}

main "$@"

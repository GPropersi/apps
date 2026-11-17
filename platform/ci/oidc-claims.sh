#!/usr/bin/env bash
# oidc-claims.sh: print the claims an operator approves a registrar identity for, from a GitHub OIDC token on stdin.
#
#   platform/ci/oidc-claims.sh < token         needs jq; prints `workflow_ref=...`, `ref=...`, `environment=...`
#
# Decodes the token payload (no signature check: the token came straight from the runner's own OIDC endpoint, and the
# claim values are only displayed). The token itself is never printed. Exit 1 on a malformed token, 2 on usage.
set -uo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: oidc-claims.sh < token" >&2
  exit 2
fi

IFS= read -r token || true
payload="$(cut -d. -f2 <<< "$token")"
if [ -z "$payload" ] || [ "$(awk -F. '{print NF}' <<< "$token")" -ne 3 ]; then
  echo "oidc-claims: not a JWT" >&2
  exit 1
fi

# base64url -> base64 with padding
payload="${payload//-/+}"
payload="${payload//_//}"
while [ $((${#payload} % 4)) -ne 0 ]; do payload="${payload}="; done

json="$(base64 -d <<< "$payload" 2> /dev/null)" || { echo "oidc-claims: the payload is not base64" >&2; exit 1; }
jq -r '"workflow_ref=\(.workflow_ref // "")", "ref=\(.ref // "")", "environment=\(.environment // "")"' <<< "$json" 2> /dev/null || {
  echo "oidc-claims: the payload is not JSON" >&2
  exit 1
}

#!/usr/bin/env bash
# notifs-key-install.sh: hand one app's freshly exchanged 4irl-notifs key to the host and check the receipt.
#
#   platform/ci/notifs-key-install.sh <app>
#
# Environment (never argv): NOTIFS_KEY, NOTIFS_ACCESS_CLIENT_ID, NOTIFS_ACCESS_CLIENT_SECRET, NOTIFS_BASE_URL,
# DEPLOY_HOST (the tailnet name of the host) and DRY_RUN (`true` or `false`; anything else is refused).
#
# DRY_RUN=true returns before any use of the key or the host: nothing is written and no connection is made. Otherwise
# the 4 stdin lines (key, client id, client secret, base URL) go to `tailscale ssh deploy@$DEPLOY_HOST notifs-key <app>`,
# which prints only sha256(key); that must equal the sha256 computed here. Only the hash is ever printed.
# Exit 0 on success (or dry run), 1 on a failure, 2 on usage.
set -uo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: notifs-key-install.sh <app>" >&2
  exit 2
fi
app="$1"

case "${DRY_RUN-}" in
  true)
    echo "notifs-key-install: dry run, nothing is written to the host for $app"
    exit 0
    ;;
  false) ;;
  *)
    echo "notifs-key-install: DRY_RUN must be true or false" >&2
    exit 2
    ;;
esac

if [ -z "${NOTIFS_KEY-}" ] || [ -z "${NOTIFS_ACCESS_CLIENT_ID-}" ] || [ -z "${NOTIFS_ACCESS_CLIENT_SECRET-}" ] || [ -z "${NOTIFS_BASE_URL-}" ]; then
  echo "notifs-key-install: the exchange gave no key, or an Access client id, secret or base URL is empty" >&2
  exit 1
fi
if [ -z "${DEPLOY_HOST-}" ]; then
  echo "notifs-key-install: DEPLOY_HOST is empty" >&2
  exit 1
fi

local_hash="$(printf '%s' "$NOTIFS_KEY" | sha256sum | cut -d' ' -f1)"
rc=0
host_hash="$(printf '%s\n%s\n%s\n%s\n' "$NOTIFS_KEY" "$NOTIFS_ACCESS_CLIENT_ID" "$NOTIFS_ACCESS_CLIENT_SECRET" "$NOTIFS_BASE_URL" | tailscale ssh "deploy@${DEPLOY_HOST}" notifs-key "$app")" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "notifs-key-install: the host refused the key for $app (rc=$rc); run the exchange again within 24 h" >&2
  exit 1
fi
if ! [[ "$host_hash" =~ ^[0-9a-f]{64}$ ]]; then
  echo "notifs-key-install: the host did not report a sha256 for $app" >&2
  exit 1
fi
if [ "$host_hash" != "$local_hash" ]; then
  echo "notifs-key-install: the host's sha256 does not match for $app" >&2
  exit 1
fi
echo "notifs-key-install: $app key installed, sha256=$local_hash"

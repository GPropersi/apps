#!/usr/bin/env bash
# check-installer-stamps.sh: refuse a deploy while a host installer differs from the commit being deployed.
#
#   platform/ci/check-installer-stamps.sh <host-rc> <host-output>      run from the repo root
#
# <host-rc> and <host-output> are the exit status and stdout of `ssh deploy@HOST stamps`: four lines
# `<name><TAB><value>` for deploy-user, data, ingress and jobs. The expected stamps are the INSTALLER_STAMP lines of
# platform/host/install-<name>.sh in the checkout. Each is recomputed with the embed tool's normalisation
# (platform/lint/embed-payloads.sh: first 16 hex of sha256 over the installer with its stamp line set to the empty value),
# so a stale stamp that reached the checkout is caught here too.
#
# Exit 0: every host installer matches. Exit 1: refusal, one line per problem plus a fixed newer-main line. Exit 2: usage,
# or an installer in the checkout whose stamp is missing, empty or stale (checked first, the host result is not consulted).
# On a non-zero host rc the host output is neither parsed nor echoed; on rc 0 a host value is echoed only if it is
# 16 lowercase hex, `missing` or `invalid`, else it prints as `unparsed` (host text never reaches the public log).
set -euo pipefail

export LC_ALL=C

if [ "$#" -ne 2 ]; then
  echo "usage: check-installer-stamps.sh <host-rc> <host-output>" >&2
  exit 2
fi
host_rc="$1"
host_out="$2"

case "$host_rc" in
  "" | *[!0-9]*) echo "check-installer-stamps: host-rc is not a number: $host_rc" >&2; exit 2 ;;
esac

names=(deploy-user data ingress jobs)
stamp_name='INSTALLER_STAMP'
hex_re='^[0-9a-f]{16}$'

declare -A expected
for name in "${names[@]}"; do
  file="platform/host/install-${name}.sh"
  [ -f "$file" ] || { echo "check-installer-stamps: $file not found (run from the repo root)" >&2; exit 2; }
  lines="$(grep -c "^readonly ${stamp_name}=" "$file" || true)"
  cur="$(sed -n "s/^readonly ${stamp_name}=//p" "$file")"
  if [ "${lines:-0}" != 1 ] || ! [[ "$cur" =~ $hex_re ]]; then
    echo "check-installer-stamps: $file stamp is stale or empty: run make embed"
    exit 2
  fi
  want="$(sed "s/^readonly ${stamp_name}=.*/readonly ${stamp_name}=/" "$file" | sha256sum | cut -c1-16)"
  if [ "$want" != "$cur" ]; then
    echo "check-installer-stamps: $file stamp is stale or empty: run make embed"
    exit 2
  fi
  expected[$name]="$cur"
done

newer_line="if the host installer is already from a newer main, re-run the latest deploy instead"
refuse() {
  printf '%s\n' "$@" "$newer_line"
  exit 1
}

if [ "$host_rc" -eq 2 ]; then
  refuse "the host dispatcher has no 'stamps' command: run \`make host-deploy-user HOST=<alias> ARGS=\"install --pubkey-file PATH\"\`"
elif [ "$host_rc" -ne 0 ]; then
  refuse "reading host installer stamps failed (rc=$host_rc); refusing to deploy blind"
fi

# Parse the host output: exactly four well-formed lines, each name once. Anything else is drift for every name.
declare -A got
well_formed=1
mapfile -t host_lines < <(printf '%s' "$host_out")
if [ "${#host_lines[@]}" -ne 4 ]; then
  well_formed=0
fi
for l in "${host_lines[@]}"; do
  if [[ "$l" =~ ^(deploy-user|data|ingress|jobs)$'\t'([^$'\t']*)$ ]]; then
    n="${BASH_REMATCH[1]}"
    if [ -n "${got[$n]+x}" ]; then
      well_formed=0
    fi
    got[$n]="${BASH_REMATCH[2]}"
  else
    well_formed=0
  fi
done

problems=()
for name in "${names[@]}"; do
  val="unparsed"
  if [ "$well_formed" -eq 1 ] && [ -n "${got[$name]+x}" ]; then
    raw="${got[$name]}"
    if [[ "$raw" =~ $hex_re ]] || [ "$raw" = "missing" ] || [ "$raw" = "invalid" ]; then
      val="$raw"
    fi
    if [ "$raw" = "${expected[$name]}" ]; then
      continue
    fi
  fi
  args='install'
  if [ "$name" = "deploy-user" ]; then
    args='install --pubkey-file PATH'
  fi
  problems+=("host installer $name differs from this commit (host $val, expected ${expected[$name]}): run \`make host-$name HOST=<alias> ARGS=\"$args\"\`")
done

if [ "${#problems[@]}" -gt 0 ]; then
  refuse "${problems[@]}"
fi
echo "check-installer-stamps: host installers match this commit"

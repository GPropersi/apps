#!/usr/bin/env bash
# check-unique-hosts.sh: cross-app claim checker for the per-app registry files apps/<name>/app.yaml.
#
#   platform/registry/check-unique-hosts.sh <app.yaml>...
#
# Each file claims the set {name, hostname (when set)}; a value claimed by two different apps is refused. That
# covers two apps sharing a hostname and a hostname equal to another app's name. One "file: reason" line per
# problem on stdout. Exit 0: no value is claimed twice. Exit 1: a clash, or a file that cannot be read or has no
# name (never skipped). Exit 2: usage (no file, or the same path given twice). Shape and reserved rules are the
# validator's job (validate-app-yaml.sh), not re-checked here.
#
# Used by `make lint` (via validate-tracked.sh) and installed beside the validator for deploy.sh's preflight, so
# lint and host agree by construction. Sources ../lib/yaml-subset.sh relative to itself, as the validator does.
# shellcheck disable=SC1091
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/yaml-subset.sh
. "$here/../lib/yaml-subset.sh"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <app.yaml>..." >&2
  exit 2
fi

declare -A seen_path=()
for f in "$@"; do
  if [ -n "${seen_path[$f]:-}" ]; then
    echo "$0: the same path given twice: $f" >&2
    exit 2
  fi
  seen_path["$f"]=1
done

problems=0
flat=""
trap 'rm -f "$flat"' EXIT
declare -A owner_file=()
declare -A owner_app=()

for f in "$@"; do
  rm -f "$flat"
  flat="$(mktemp)"
  if ! ys_flatten < "$f" > "$flat" 2> /dev/null; then
    printf '%s: cannot read name\n' "$f"
    problems=$((problems + 1))
    continue
  fi
  name="$(ys_get "$flat" name)"
  if [ -z "$name" ]; then
    printf '%s: cannot read name\n' "$f"
    problems=$((problems + 1))
    continue
  fi
  hostname="$(ys_get "$flat" hostname)"
  claims=("$name")
  if [ -n "$hostname" ] && [ "$hostname" != "$name" ]; then
    claims+=("$hostname")
  fi
  for v in "${claims[@]}"; do
    if [ -n "${owner_file[$v]:-}" ]; then
      printf "%s: '%s' is also claimed by app '%s' (%s)\n" "$f" "$v" "${owner_app[$v]}" "${owner_file[$v]}"
      problems=$((problems + 1))
    else
      owner_file["$v"]="$f"
      owner_app["$v"]="$name"
    fi
  done
done

[ "$problems" -eq 0 ] || exit 1
exit 0

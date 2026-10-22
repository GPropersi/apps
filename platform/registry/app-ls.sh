#!/usr/bin/env bash
# app-ls.sh: list the registered apps (apps/*/app.yaml), optionally joined with live container state.
#
#   platform/registry/app-ls.sh [--root DIR] [--live-from FILE]
#
# Without --live-from the table is registry only (offline) and STATE is "-". With it, FILE holds the output of
# `platform ls` (TSV, `app<TAB>state<TAB>health`, one row per app; contract in platform/registry/README.md).
# Columns: APP OWNER TEMPLATE MEM ACCESS STATE. STATE folds health in as `<state> (<health>)` when health is
# not `none`; a registered app with no live row is `not deployed`; a live app with no registry entry is
# `UNREGISTERED` (listed, exit 1).
#
# Fail closed: an invalid app.yaml or malformed live input prints an error and exits 1 with no table.
# Exit codes: 0 listed | 1 invalid registry or live input, or an unregistered app | 2 usage.
# --root DIR is the repo root holding apps/ (default: this script's repo); it exists for the tests.
# shellcheck disable=SC1091
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/yaml-subset.sh
. "$here/../lib/yaml-subset.sh"

APP_RE='^[a-z][a-z0-9-]{1,30}$'
root="$(cd "$here/../.." && pwd)"
live_file=""
have_live=0

usage() {
  echo "usage: $0 [--root DIR] [--live-from FILE]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || usage
      root="$2"
      shift 2
      ;;
    --live-from)
      [ "$#" -ge 2 ] || usage
      live_file="$2"
      have_live=1
      shift 2
      ;;
    *) usage ;;
  esac
done

die() {
  echo "app-ls: $1" >&2
  exit 1
}

work="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$work"' EXIT

# Registry: validate everything first, then read the fields.
files=()
for f in "$root"/apps/*/app.yaml; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  files+=("$f")
done
if [ "${#files[@]}" -gt 0 ]; then
  if ! "$here/validate-app-yaml.sh" "${files[@]}" > "$work/validate.txt" 2>&1; then
    cat "$work/validate.txt" >&2
    die "invalid app.yaml, no table printed"
  fi
fi

: > "$work/registry.tsv"
for f in "${files[@]}"; do
  ys_flatten < "$f" > "$work/flat.tsv" 2> "$work/flat.err" || die "cannot read $f: $(head -n 1 "$work/flat.err")"
  access="$(ys_get "$work/flat.tsv" access)"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(ys_get "$work/flat.tsv" name)" "$(ys_get "$work/flat.tsv" owner)" "$(ys_get "$work/flat.tsv" template)" \
    "$(ys_get "$work/flat.tsv" memory_cap)" "${access:-family}" >> "$work/registry.tsv"
done
LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$work/registry.tsv" > "$work/registry.sorted.tsv"

# Live input: every row must be exactly app, state, health with known shapes, one row per app.
in_live() { awk -F '\t' -v a="$1" '$1 == a { f = 1 } END { exit f ? 0 : 1 }' "$work/live.tsv"; }

: > "$work/live.tsv"
if [ "$have_live" -eq 1 ]; then
  [ -f "$live_file" ] && [ -r "$live_file" ] || die "live file '$live_file' is not a readable file"
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    cols="$(awk -F '\t' '{ print NF }' <<< "$line")"
    [ "$cols" -eq 3 ] || die "live row $n has $cols columns, want 3 (app, state, health)"
    IFS=$'\t' read -r l_app l_state l_health <<< "$line"
    [[ "$l_app" =~ $APP_RE ]] || die "live row $n has an invalid app name"
    [[ "$l_state" =~ ^[a-z]+$ ]] || die "live row $n has an invalid state"
    case "$l_health" in none | healthy | starting | unhealthy) ;; *) die "live row $n has an invalid health value" ;; esac
    if in_live "$l_app"; then die "live row $n repeats app '$l_app'"; fi
    printf '%s\t%s\t%s\n' "$l_app" "$l_state" "$l_health" >> "$work/live.tsv"
  done < "$live_file"
fi

live_state() { # app: prints the folded STATE for a live row
  local s h
  IFS=$'\t' read -r s h < <(awk -F '\t' -v a="$1" '$1 == a { print $2 "\t" $3; exit }' "$work/live.tsv") || true
  if [ "$h" = none ] || [ -z "$h" ]; then printf '%s' "$s"; else printf '%s (%s)' "$s" "$h"; fi
}

row() { printf '%-32s %-32s %-14s %-6s %-11s %s\n' "$@"; }

row APP OWNER TEMPLATE MEM ACCESS STATE
registered=" "
while IFS=$'\t' read -r name owner template mem access; do
  [ -n "$name" ] || continue
  registered="$registered$name "
  if [ "$have_live" -eq 0 ]; then
    state="-"
  elif in_live "$name"; then
    state="$(live_state "$name")"
  else
    state="not deployed"
  fi
  row "$name" "$owner" "$template" "$mem" "$access" "$state"
done < "$work/registry.sorted.tsv"

rc=0
while IFS=$'\t' read -r l_app _; do
  [ -n "$l_app" ] || continue
  case "$registered" in
    *" $l_app "*) ;;
    *)
      row "$l_app" - - - - UNREGISTERED
      rc=1
      ;;
  esac
done < <(LC_ALL=C sort "$work/live.tsv")
[ "$rc" -eq 0 ] || echo "app-ls: labelled containers with no apps/<name>/app.yaml (UNREGISTERED)" >&2
exit "$rc"

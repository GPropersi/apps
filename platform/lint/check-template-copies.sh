#!/usr/bin/env bash
# check-template-copies.sh: the helper drift lint `make lint` enforces. Each problem prints `<path>: <reason>` on stdout
# and the script exits 1 (2 on usage).
#
#   platform/lint/check-template-copies.sh [--root DIR]      DIR is a git work tree (default: the git top level)
#
# The go-react template's Go helper package, templates/go-react/internal/platform/, is copied into every app by
# `make app-new` (an app's Docker build context is apps/<name>/ only, so it cannot import from templates/). For every
# tracked apps/<name>/app.yaml declaring `template: go-react`:
#   1. apps/<name>/internal/platform/ must hold the same file set as the template's, every file byte-identical;
#      a mismatch lists the differing files, with the fix (copy the template's directory over the app's);
#   2. the template's helper directory must not contain the placeholder app name.
# Compares git index entries (mode and blob hash), so a symlink or an executable-bit difference is drift too. Reads only
# git-tracked files, so a file that is not `git add`ed is not seen. With no go-react app the lint passes trivially.
set -uo pipefail

root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "missing value for --root" >&2; exit 2; }; root="$2"; shift 2 ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$root" ] || root="$(git rev-parse --show-toplevel)" || exit 2

placeholder="tmpl""goreact"
helper="templates/go-react/internal/platform"
fix="copy the template's directory over the app's: rm -r apps/<name>/internal/platform && cp -R $helper apps/<name>/internal/platform"

problems=0
problem() {
  echo "$1: $2"
  problems=$((problems + 1))
}

tracked="$(git -C "$root" ls-files -z -- 'apps/*' 'templates/*' | tr '\0' '\n')" || exit 2

# top_value <app.yaml path> <key>: the top-level scalar, quotes removed.
top_value() {
  awk -v k="$2" '
    index($0, k ":") == 1 { sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]+$/, ""); gsub(/^["\047]|["\047]$/, ""); print; exit }' "$root/$1"
}

# files_under <dir>: tracked files under dir, relative to it.
files_under() {
  local p="$1/"
  grep -F -- "$p" <<< "$tracked" | awk -v p="$p" 'index($0, p) == 1 { print substr($0, length(p) + 1) }' | LC_ALL=C sort
}

# entry <dir> <relative file>: the index entry "mode blob-hash" of a tracked file. Comparing these (not file contents)
# also catches a symlink (mode 120000) or an executable-bit difference, and reads only tracked state.
entry() {
  git -C "$root" ls-files -s -- "$1/$2" | awk '{ print $1 " " $2; exit }'
}

template_files="$(files_under "$helper")"

# 2. the template's helper directory never names the placeholder app.
if [ -n "$template_files" ]; then
  while IFS= read -r f; do
    if [[ "$f" == *"$placeholder"* ]] || grep -qa -- "$placeholder" "$root/$helper/$f"; then
      problem "$helper/$f" "names the placeholder app '$placeholder' (the helper package is copied into every app unchanged)"
    fi
  done <<< "$template_files"
fi

# 1. every go-react app's copy equals the template's.
while IFS= read -r yaml; do
  [ -n "$yaml" ] || continue
  case "$yaml" in apps/*/app.yaml) ;; *) continue ;; esac
  dir="${yaml%/app.yaml}"
  case "${dir#apps/}" in */*) continue ;; *) ;; esac
  [ "$(top_value "$yaml" template)" = "go-react" ] || continue
  if [ -z "$template_files" ]; then
    problem "$dir" "declares template go-react but $helper has no tracked files to compare against"
    continue
  fi
  app_files="$(files_under "$dir/internal/platform")"
  if [ -z "$app_files" ]; then
    problem "$dir/internal/platform" "missing: a go-react app carries a copy of $helper ($fix)"
    continue
  fi
  differ=""
  while IFS= read -r f; do
    if ! grep -qxF -- "$f" <<< "$app_files"; then
      differ="$differ $f(missing)"
    elif [ "$(entry "$helper" "$f")" != "$(entry "$dir/internal/platform" "$f")" ]; then
      differ="$differ $f(differs)"
    fi
  done <<< "$template_files"
  while IFS= read -r f; do
    grep -qxF -- "$f" <<< "$template_files" || differ="$differ $f(extra)"
  done <<< "$app_files"
  if [ -n "$differ" ]; then
    problem "$dir/internal/platform" "differs from $helper:$differ ($fix)"
  fi
done <<< "$tracked"

if [ "$problems" -ne 0 ]; then
  exit 1
fi
echo "check-template-copies: OK"

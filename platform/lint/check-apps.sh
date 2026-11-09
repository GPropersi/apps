#!/usr/bin/env bash
# check-apps.sh: the per-app contract `make lint` enforces. Each problem prints `<path>: <reason>` on stdout and
# the script exits 1 (2 on usage).
#
#   platform/lint/check-apps.sh [--root DIR]      DIR is a git work tree (default: the git top level)
#
# For every tracked apps/<name>/app.yaml:
#   1. at least one tracked apps/<name>/test_*.sh;
#   2. a tracked apps/<name>/Dockerfile;
#   3. every FROM pinned as @sha256:<64 hex>, unless it names an earlier stage alias or is the literal `scratch`;
#   4. the last USER of the final stage is a literal numeric non-zero uid (`1000`, `1000:1000`); a name, root, any
#      zero form, a $-expanded value, or no USER in the final stage is refused.
# The USER check is a heuristic and may refuse a legitimate form such as an ARG-expanded USER; the deploy-time image
# `inspect` check stays the authority (heredoc bodies are scanned as instructions; that also fails closed or is
# harmless). No apps passes.
#   5. an app declaring `template: go-react` has no `access` key or `access: family` (the template validates one shared
#      Access audience, so `public` and `restricted` are refused, naming the key).
set -uo pipefail

root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "missing value for --root" >&2; exit 2; }; root="$2"; shift 2 ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$root" ] || root="$(git rev-parse --show-toplevel)" || exit 2

problems=0
problem() {
  echo "$1: $2"
  problems=$((problems + 1))
}

tracked="$(git -C "$root" ls-files -z -- 'apps/*' | tr '\0' '\n')" || exit 2

# check_dockerfile <relative path>
check_dockerfile() {
  local path="$1" line word rest image alias_name user_val stage=0 final_user="" aliases=" "
  local lc
  set -f # the unquoted word splits below must not glob
  # Join backslash continuations and drop comment lines.
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in '' | '#'*) continue ;; esac
    word="${line%%[[:space:]]*}"
    rest="${line#"$word"}"
    lc="$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')"
    case "$lc" in
      from)
        stage=$((stage + 1))
        final_user=""
        # shellcheck disable=SC2086
        set -- $rest
        while [ $# -gt 0 ]; do
          case "$1" in --*) shift ;; *) break ;; esac
        done
        image="${1:-}"
        alias_name=""
        if [ "${2:-}" != "" ]; then
          if [ "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" = "as" ]; then alias_name="${3:-}"; fi
        fi
        if [ -z "$image" ]; then
          problem "$path" "FROM without an image"
        elif [ "$image" = "scratch" ]; then
          :
        elif [[ "$aliases" == *" $(printf '%s' "$image" | tr '[:upper:]' '[:lower:]') "* ]]; then
          :
        elif ! [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
          problem "$path" "FROM $image is not pinned as @sha256:<64 hex>"
        fi
        if [ -n "$alias_name" ]; then aliases="$aliases$(printf '%s' "$alias_name" | tr '[:upper:]' '[:lower:]') "; fi
        ;;
      user)
        # shellcheck disable=SC2086
        set -- $rest
        final_user="${1:-}"
        ;;
    esac
  done < <(sed -e '/^[[:space:]]*#/d' -e ':a' -e '/\\$/{N;s/\\\n/ /;ba' -e '}' "$root/$path")
  if [ "$stage" -eq 0 ]; then
    problem "$path" "no FROM instruction"
    return
  fi
  if [ -z "$final_user" ]; then
    problem "$path" "final stage has no USER (needs a numeric non-zero uid such as USER 1000)"
    return
  fi
  user_val="${final_user%%:*}"
  if ! [[ "$user_val" =~ ^[0-9]+$ ]] || [[ "$user_val" =~ ^0+$ ]]; then
    problem "$path" "final-stage USER $final_user is not a literal numeric non-zero uid"
  fi
}

# top_value <app.yaml path> <key>: the top-level scalar, quotes removed (empty when absent).
top_value() {
  awk -v k="$2" '
    index($0, k ":") == 1 { sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]+$/, ""); gsub(/^["\047]|["\047]$/, ""); print; exit }' "$root/$1"
}

while IFS= read -r yaml; do
  [ -n "$yaml" ] || continue
  case "$yaml" in apps/*/app.yaml) ;; *) continue ;; esac
  dir="${yaml%/app.yaml}"
  name="${dir#apps/}"
  case "$name" in */*) continue ;; esac
  if [ "$(top_value "$yaml" template)" = "go-react" ] && grep -q '^access:' "$root/$yaml"; then
    access="$(top_value "$yaml" access)"
    if [ "$access" != "family" ]; then
      problem "$yaml" "access '$access' is not supported by template go-react: the template validates one shared Access audience, so only an absent access key or access: family passes"
    fi
  fi
  if ! grep -qE "^$dir/test_[^/]*\.sh\$" <<< "$tracked"; then
    problem "$dir" "no tracked test_*.sh (every app ships a test script)"
  fi
  if ! grep -qxF "$dir/Dockerfile" <<< "$tracked"; then
    problem "$dir" "no tracked Dockerfile"
  else
    check_dockerfile "$dir/Dockerfile"
  fi
done <<< "$tracked"

if [ "$problems" -ne 0 ]; then
  exit 1
fi
echo "check-apps: OK"

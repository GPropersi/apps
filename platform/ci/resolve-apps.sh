#!/usr/bin/env bash
# resolve-apps.sh: validate the app list a deploy run will fan out over, and print it as a compact JSON array.
#
#   platform/ci/resolve-apps.sh call <json-array>        the list a caller (ci.yml) passes
#   platform/ci/resolve-apps.sh dispatch <all|name>      a manual run: every app, or one tracked app
#
# Every element on both paths must match the registry app-name regex ^[a-z][a-z0-9-]{1,30}$, else exit 1 naming the
# element; a non-array exits 1. `dispatch` takes the list from changed-apps.sh with the all-zero before: `all` prints it,
# a name must be in it (prints [name]), else exit 1. An empty list prints [] and exits 0. Run inside the git checkout
# (dispatch reads the tracked apps); needs jq. Exit 2 on usage.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
re='^[a-z][a-z0-9-]{1,30}$'

if [ "$#" -ne 2 ]; then
  echo "usage: resolve-apps.sh call <json-array> | dispatch <all|name>" >&2
  exit 2
fi
mode="$1"
arg="$2"

# validate <json>: prints the compact array when every element is a valid name.
validate() {
  local json="$1" compact bad
  compact="$(jq -c 'if type == "array" and all(.[]; type == "string") then . else error("not an array of strings") end' <<< "$json" 2> /dev/null)" || {
    echo "resolve-apps: input is not a JSON array of strings" >&2
    return 1
  }
  # Validated inside jq so an empty element or one with an embedded newline cannot slip past a line-based loop.
  bad="$(jq -r --arg re "$re" '.[] | select((test($re) and (contains("\n") | not)) | not) | @json' <<< "$compact" | head -n 1)"
  if [ -n "$bad" ]; then
    echo "resolve-apps: invalid app name: $bad" >&2
    return 1
  fi
  printf '%s\n' "$compact"
}

case "$mode" in
  call)
    validate "$arg"
    ;;
  dispatch)
    zero="$(printf '0%.0s' $(seq 40))"
    list="$("$here/changed-apps.sh" "$zero" HEAD)" || { echo "resolve-apps: cannot list the tracked apps" >&2; exit 1; }
    list="$(validate "$list")" || exit 1
    if [ "$arg" = "all" ]; then
      printf '%s\n' "$list"
      exit 0
    fi
    if ! [[ "$arg" =~ $re ]]; then
      echo "resolve-apps: invalid app name: $arg" >&2
      exit 1
    fi
    if jq -e --arg a "$arg" 'index($a) != null' <<< "$list" > /dev/null; then
      jq -nc --arg a "$arg" '[$a]'
    else
      echo "resolve-apps: not a tracked app: $arg" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: resolve-apps.sh call <json-array> | dispatch <all|name>" >&2
    exit 2
    ;;
esac
